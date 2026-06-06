// PEGPU RTP/CoreAudio bridge.
//
// Receives PipeWire RTP PCM from the VM and plays it through the current
// macOS default output. With --mic, captures the current macOS default input
// and sends RTP PCM back to PipeWire in the VM.

#include <AudioToolbox/AudioToolbox.h>
#include <CoreAudio/CoreAudio.h>
#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define RTP_PAYLOAD_TYPE 127
#define DEFAULT_SAMPLE_RATE 48000
#define DEFAULT_CHANNELS 2
#define DEFAULT_LISTEN_PORT 47110
#define DEFAULT_SEND_PORT 47111
#define DEFAULT_BUFFER_MS 20
#define DEFAULT_AUDIOQUEUE_MS 10
#define OUTPUT_RING_SECONDS 2
#define MAX_PACKET_BYTES 1500
#define SSRC_MAC_MIC 0x76656761u

static volatile sig_atomic_t g_running = 1;

typedef struct {
    int16_t *samples;
    size_t capacity;
    size_t read_index;
    size_t write_index;
    size_t count;
    pthread_mutex_t mutex;
} SampleRing;

typedef struct {
    char vm_host[128];
    uint16_t listen_port;
    uint16_t send_port;
    int sample_rate;
    int channels;
    int buffer_ms;
    bool mic_enabled;
} Config;

typedef struct {
    Config config;
    SampleRing playback;
    int receive_fd;
    int send_fd;
    struct sockaddr_in send_addr;
    AudioQueueRef output_queue;
    AudioQueueRef input_queue;
    uint16_t mic_sequence;
    uint32_t mic_timestamp;
    uint64_t underruns;
    uint64_t late_or_bad_packets;
} Bridge;

static void handle_signal(int signo) {
    (void)signo;
    g_running = 0;
}

static uint16_t read_be16(const uint8_t *p) {
    return (uint16_t)(((uint16_t)p[0] << 8) | p[1]);
}

static void write_be16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)(v >> 8);
    p[1] = (uint8_t)(v & 0xff);
}

static void write_be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24);
    p[1] = (uint8_t)((v >> 16) & 0xff);
    p[2] = (uint8_t)((v >> 8) & 0xff);
    p[3] = (uint8_t)(v & 0xff);
}

static bool ring_init(SampleRing *ring, size_t capacity) {
    memset(ring, 0, sizeof(*ring));
    ring->samples = calloc(capacity, sizeof(int16_t));
    if (!ring->samples) {
        return false;
    }
    ring->capacity = capacity;
    pthread_mutex_init(&ring->mutex, NULL);
    return true;
}

static void ring_destroy(SampleRing *ring) {
    if (!ring) {
        return;
    }
    free(ring->samples);
    pthread_mutex_destroy(&ring->mutex);
    memset(ring, 0, sizeof(*ring));
}

static size_t ring_count(SampleRing *ring) {
    pthread_mutex_lock(&ring->mutex);
    size_t count = ring->count;
    pthread_mutex_unlock(&ring->mutex);
    return count;
}

static void ring_drop_oldest_unlocked(SampleRing *ring, size_t samples) {
    if (samples > ring->count) {
        samples = ring->count;
    }
    ring->read_index = (ring->read_index + samples) % ring->capacity;
    ring->count -= samples;
}

static void ring_write(SampleRing *ring, const int16_t *samples, size_t count) {
    pthread_mutex_lock(&ring->mutex);
    if (count > ring->capacity) {
        samples += count - ring->capacity;
        count = ring->capacity;
    }
    if (ring->capacity - ring->count < count) {
        ring_drop_oldest_unlocked(ring, count - (ring->capacity - ring->count));
    }
    for (size_t i = 0; i < count; i++) {
        ring->samples[ring->write_index] = samples[i];
        ring->write_index = (ring->write_index + 1) % ring->capacity;
    }
    ring->count += count;
    pthread_mutex_unlock(&ring->mutex);
}

static size_t ring_read(SampleRing *ring, int16_t *out, size_t count) {
    pthread_mutex_lock(&ring->mutex);
    size_t got = count < ring->count ? count : ring->count;
    for (size_t i = 0; i < got; i++) {
        out[i] = ring->samples[ring->read_index];
        ring->read_index = (ring->read_index + 1) % ring->capacity;
    }
    ring->count -= got;
    pthread_mutex_unlock(&ring->mutex);
    if (got < count) {
        memset(out + got, 0, (count - got) * sizeof(int16_t));
    }
    return got;
}

static void usage(FILE *out) {
    fprintf(out,
        "usage: pegpu-audio-host --vm <ip> [--listen <port>] [--send <port>] [--mic] [--buffer-ms <ms>]\n"
        "\n"
        "Defaults: listen=%d send=%d sample-rate=%d channels=%d buffer-ms=%d\n",
        DEFAULT_LISTEN_PORT, DEFAULT_SEND_PORT, DEFAULT_SAMPLE_RATE, DEFAULT_CHANNELS, DEFAULT_BUFFER_MS);
}

static bool parse_u16(const char *raw, uint16_t *out) {
    char *end = NULL;
    long value = strtol(raw, &end, 10);
    if (!raw[0] || (end && *end) || value <= 0 || value > 65535) {
        return false;
    }
    *out = (uint16_t)value;
    return true;
}

static bool parse_int_range(const char *raw, int min, int max, int *out) {
    char *end = NULL;
    long value = strtol(raw, &end, 10);
    if (!raw[0] || (end && *end) || value < min || value > max) {
        return false;
    }
    *out = (int)value;
    return true;
}

static bool parse_args(int argc, char **argv, Config *config) {
    memset(config, 0, sizeof(*config));
    config->listen_port = DEFAULT_LISTEN_PORT;
    config->send_port = DEFAULT_SEND_PORT;
    config->sample_rate = DEFAULT_SAMPLE_RATE;
    config->channels = DEFAULT_CHANNELS;
    config->buffer_ms = DEFAULT_BUFFER_MS;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            usage(stdout);
            exit(0);
        } else if (!strcmp(argv[i], "--vm") && i + 1 < argc) {
            snprintf(config->vm_host, sizeof(config->vm_host), "%s", argv[++i]);
        } else if (!strcmp(argv[i], "--listen") && i + 1 < argc) {
            if (!parse_u16(argv[++i], &config->listen_port)) {
                fprintf(stderr, "invalid --listen port\n");
                return false;
            }
        } else if (!strcmp(argv[i], "--send") && i + 1 < argc) {
            if (!parse_u16(argv[++i], &config->send_port)) {
                fprintf(stderr, "invalid --send port\n");
                return false;
            }
        } else if (!strcmp(argv[i], "--buffer-ms") && i + 1 < argc) {
            if (!parse_int_range(argv[++i], 5, 250, &config->buffer_ms)) {
                fprintf(stderr, "invalid --buffer-ms; expected 5..250\n");
                return false;
            }
        } else if (!strcmp(argv[i], "--mic")) {
            config->mic_enabled = true;
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            return false;
        }
    }
    if (config->vm_host[0] == '\0') {
        fprintf(stderr, "--vm is required\n");
        return false;
    }
    return true;
}

static bool open_receive_socket(Bridge *bridge) {
    bridge->receive_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (bridge->receive_fd < 0) {
        perror("socket receive");
        return false;
    }
    int yes = 1;
    setsockopt(bridge->receive_fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(bridge->config.listen_port);
    if (bind(bridge->receive_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        perror("bind receive");
        return false;
    }
    struct timeval tv;
    tv.tv_sec = 0;
    tv.tv_usec = 100000;
    setsockopt(bridge->receive_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    return true;
}

static bool open_send_socket(Bridge *bridge) {
    bridge->send_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (bridge->send_fd < 0) {
        perror("socket send");
        return false;
    }
    memset(&bridge->send_addr, 0, sizeof(bridge->send_addr));
    bridge->send_addr.sin_family = AF_INET;
    bridge->send_addr.sin_port = htons(bridge->config.send_port);
    if (inet_pton(AF_INET, bridge->config.vm_host, &bridge->send_addr.sin_addr) != 1) {
        fprintf(stderr, "invalid VM IPv4 address: %s\n", bridge->config.vm_host);
        return false;
    }
    return true;
}

static size_t rtp_payload_offset(const uint8_t *packet, size_t length) {
    if (length < 12 || (packet[0] >> 6) != 2) {
        return 0;
    }
    size_t offset = 12 + ((size_t)(packet[0] & 0x0f) * 4);
    if (offset > length) {
        return 0;
    }
    if (packet[0] & 0x10) {
        if (offset + 4 > length) {
            return 0;
        }
        uint16_t extension_words = read_be16(packet + offset + 2);
        offset += 4 + ((size_t)extension_words * 4);
        if (offset > length) {
            return 0;
        }
    }
    return offset;
}

static void *receive_thread_main(void *opaque) {
    Bridge *bridge = opaque;
    uint8_t packet[MAX_PACKET_BYTES];
    int16_t samples[(MAX_PACKET_BYTES / 2)];
    while (g_running) {
        ssize_t got = recv(bridge->receive_fd, packet, sizeof(packet), 0);
        if (got < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                continue;
            }
            perror("recv");
            break;
        }
        size_t offset = rtp_payload_offset(packet, (size_t)got);
        if (!offset || offset >= (size_t)got) {
            bridge->late_or_bad_packets++;
            continue;
        }
        size_t payload_bytes = (size_t)got - offset;
        if (payload_bytes % 2) {
            payload_bytes--;
        }
        size_t sample_count = payload_bytes / 2;
        for (size_t i = 0; i < sample_count; i++) {
            uint16_t be = read_be16(packet + offset + (i * 2));
            samples[i] = (int16_t)be;
        }
        ring_write(&bridge->playback, samples, sample_count);
    }
    return NULL;
}

static AudioStreamBasicDescription audio_description(const Config *config) {
    AudioStreamBasicDescription desc;
    memset(&desc, 0, sizeof(desc));
    desc.mSampleRate = config->sample_rate;
    desc.mFormatID = kAudioFormatLinearPCM;
    desc.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
    desc.mBitsPerChannel = 16;
    desc.mChannelsPerFrame = (UInt32)config->channels;
    desc.mFramesPerPacket = 1;
    desc.mBytesPerFrame = (UInt32)(config->channels * sizeof(int16_t));
    desc.mBytesPerPacket = desc.mBytesPerFrame;
    return desc;
}

static void output_callback(void *opaque, AudioQueueRef queue, AudioQueueBufferRef buffer) {
    Bridge *bridge = opaque;
    size_t frames = (size_t)(bridge->config.sample_rate * DEFAULT_AUDIOQUEUE_MS / 1000);
    size_t samples = frames * (size_t)bridge->config.channels;
    size_t bytes = samples * sizeof(int16_t);
    if (buffer->mAudioDataBytesCapacity < bytes) {
        bytes = buffer->mAudioDataBytesCapacity;
        samples = bytes / sizeof(int16_t);
    }
    size_t got = ring_read(&bridge->playback, buffer->mAudioData, samples);
    if (got < samples) {
        bridge->underruns++;
    }
    buffer->mAudioDataByteSize = (UInt32)bytes;
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static bool start_output(Bridge *bridge) {
    AudioStreamBasicDescription desc = audio_description(&bridge->config);
    OSStatus status = AudioQueueNewOutput(&desc, output_callback, bridge, NULL, NULL, 0, &bridge->output_queue);
    if (status != noErr) {
        fprintf(stderr, "AudioQueueNewOutput failed: %d\n", (int)status);
        return false;
    }
    UInt32 frames = (UInt32)(bridge->config.sample_rate * DEFAULT_AUDIOQUEUE_MS / 1000);
    UInt32 bytes = frames * desc.mBytesPerFrame;
    for (int i = 0; i < 4; i++) {
        AudioQueueBufferRef buffer = NULL;
        status = AudioQueueAllocateBuffer(bridge->output_queue, bytes, &buffer);
        if (status != noErr) {
            fprintf(stderr, "AudioQueueAllocateBuffer output failed: %d\n", (int)status);
            return false;
        }
        memset(buffer->mAudioData, 0, bytes);
        buffer->mAudioDataByteSize = bytes;
        AudioQueueEnqueueBuffer(bridge->output_queue, buffer, 0, NULL);
    }

    size_t target_samples = (size_t)bridge->config.sample_rate * (size_t)bridge->config.channels * (size_t)bridge->config.buffer_ms / 1000;
    for (int i = 0; i < 200 && g_running; i++) {
        if (ring_count(&bridge->playback) >= target_samples) {
            break;
        }
        usleep(10000);
    }
    status = AudioQueueStart(bridge->output_queue, NULL);
    if (status != noErr) {
        fprintf(stderr, "AudioQueueStart output failed: %d\n", (int)status);
        return false;
    }
    return true;
}

static void send_rtp_packet(Bridge *bridge, const int16_t *samples, size_t frame_count) {
    uint8_t packet[MAX_PACKET_BYTES];
    size_t sample_count = frame_count * (size_t)bridge->config.channels;
    size_t payload_bytes = sample_count * sizeof(int16_t);

    packet[0] = 0x80;
    packet[1] = RTP_PAYLOAD_TYPE;
    write_be16(packet + 2, bridge->mic_sequence++);
    write_be32(packet + 4, bridge->mic_timestamp);
    write_be32(packet + 8, SSRC_MAC_MIC);
    for (size_t i = 0; i < sample_count; i++) {
        write_be16(packet + 12 + (i * 2), (uint16_t)samples[i]);
    }
    sendto(bridge->send_fd, packet, payload_bytes + 12, 0, (struct sockaddr *)&bridge->send_addr, sizeof(bridge->send_addr));
    bridge->mic_timestamp += (uint32_t)frame_count;
}

static void send_rtp_pcm(Bridge *bridge, const int16_t *samples, size_t sample_count) {
    size_t channels = (size_t)bridge->config.channels;
    size_t frame_count = sample_count / channels;
    if (frame_count == 0) {
        return;
    }

    size_t max_payload_samples = (MAX_PACKET_BYTES - 12) / sizeof(int16_t);
    size_t max_packet_frames = max_payload_samples / channels;
    size_t preferred_packet_frames = (size_t)bridge->config.sample_rate * 5 / 1000;
    if (preferred_packet_frames == 0 || preferred_packet_frames > max_packet_frames) {
        preferred_packet_frames = max_packet_frames;
    }

    while (frame_count > 0) {
        size_t packet_frames = frame_count < preferred_packet_frames ? frame_count : preferred_packet_frames;
        send_rtp_packet(bridge, samples, packet_frames);
        samples += packet_frames * channels;
        frame_count -= packet_frames;
    }
}

static void input_callback(void *opaque, AudioQueueRef queue, AudioQueueBufferRef buffer, const AudioTimeStamp *start_time, UInt32 packets, const AudioStreamPacketDescription *packet_desc) {
    (void)start_time;
    (void)packets;
    (void)packet_desc;
    Bridge *bridge = opaque;
    if (g_running && buffer->mAudioDataByteSize > 0) {
        send_rtp_pcm(bridge, buffer->mAudioData, buffer->mAudioDataByteSize / sizeof(int16_t));
    }
    AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
}

static bool start_input(Bridge *bridge) {
    AudioStreamBasicDescription desc = audio_description(&bridge->config);
    OSStatus status = AudioQueueNewInput(&desc, input_callback, bridge, NULL, NULL, 0, &bridge->input_queue);
    if (status != noErr) {
        fprintf(stderr, "AudioQueueNewInput failed: %d\n", (int)status);
        return false;
    }
    UInt32 frames = (UInt32)(bridge->config.sample_rate * DEFAULT_AUDIOQUEUE_MS / 1000);
    UInt32 bytes = frames * desc.mBytesPerFrame;
    for (int i = 0; i < 4; i++) {
        AudioQueueBufferRef buffer = NULL;
        status = AudioQueueAllocateBuffer(bridge->input_queue, bytes, &buffer);
        if (status != noErr) {
            fprintf(stderr, "AudioQueueAllocateBuffer input failed: %d\n", (int)status);
            return false;
        }
        AudioQueueEnqueueBuffer(bridge->input_queue, buffer, 0, NULL);
    }
    status = AudioQueueStart(bridge->input_queue, NULL);
    if (status != noErr) {
        fprintf(stderr, "AudioQueueStart input failed: %d\n", (int)status);
        return false;
    }
    return true;
}

int main(int argc, char **argv) {
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);

    Bridge bridge;
    memset(&bridge, 0, sizeof(bridge));
    bridge.receive_fd = -1;
    bridge.send_fd = -1;
    if (!parse_args(argc, argv, &bridge.config)) {
        usage(stderr);
        return 2;
    }
    size_t ring_samples = (size_t)bridge.config.sample_rate * (size_t)bridge.config.channels * OUTPUT_RING_SECONDS;
    if (!ring_init(&bridge.playback, ring_samples)) {
        fprintf(stderr, "could not allocate playback ring\n");
        return 1;
    }
    if (!open_receive_socket(&bridge) || !open_send_socket(&bridge)) {
        ring_destroy(&bridge.playback);
        return 1;
    }

    pthread_t receive_thread;
    if (pthread_create(&receive_thread, NULL, receive_thread_main, &bridge) != 0) {
        perror("pthread_create receive");
        ring_destroy(&bridge.playback);
        return 1;
    }

    if (!start_output(&bridge)) {
        g_running = 0;
    }
    if (g_running && bridge.config.mic_enabled && !start_input(&bridge)) {
        fprintf(stderr, "microphone capture disabled after input start failure\n");
    }

    fprintf(stderr, "PEGPU audio bridge running: vm=%s listen=%u send=%u mic=%s buffer_ms=%d\n",
            bridge.config.vm_host,
            bridge.config.listen_port,
            bridge.config.send_port,
            bridge.config.mic_enabled ? "on" : "off",
            bridge.config.buffer_ms);

    while (g_running) {
        sleep(1);
    }

    if (bridge.input_queue) {
        AudioQueueStop(bridge.input_queue, true);
        AudioQueueDispose(bridge.input_queue, true);
    }
    if (bridge.output_queue) {
        AudioQueueStop(bridge.output_queue, true);
        AudioQueueDispose(bridge.output_queue, true);
    }
    if (bridge.receive_fd >= 0) {
        close(bridge.receive_fd);
    }
    if (bridge.send_fd >= 0) {
        close(bridge.send_fd);
    }
    pthread_join(receive_thread, NULL);
    ring_destroy(&bridge.playback);

    fprintf(stderr, "PEGPU audio bridge stopped: underruns=%llu bad_packets=%llu\n",
            (unsigned long long)bridge.underruns,
            (unsigned long long)bridge.late_or_bad_packets);
    return 0;
}
