const canvas = document.getElementById("signal-canvas");
const ctx = canvas.getContext("2d");
const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

let width = 0;
let height = 0;
let points = [];
let raf = 0;

function resize() {
  const scale = Math.min(window.devicePixelRatio || 1, 2);
  width = window.innerWidth;
  height = window.innerHeight;
  canvas.width = Math.floor(width * scale);
  canvas.height = Math.floor(height * scale);
  canvas.style.width = `${width}px`;
  canvas.style.height = `${height}px`;
  ctx.setTransform(scale, 0, 0, scale, 0, 0);

  const count = Math.max(28, Math.min(72, Math.floor((width * height) / 30000)));
  points = Array.from({ length: count }, (_, index) => ({
    x: (index * 131) % width,
    y: (index * 79) % height,
    vx: ((index % 5) - 2) * 0.06,
    vy: (((index + 2) % 5) - 2) * 0.05,
  }));
}

function draw() {
  ctx.clearRect(0, 0, width, height);
  ctx.lineWidth = 1;

  for (const point of points) {
    point.x += point.vx;
    point.y += point.vy;

    if (point.x < -20) point.x = width + 20;
    if (point.x > width + 20) point.x = -20;
    if (point.y < -20) point.y = height + 20;
    if (point.y > height + 20) point.y = -20;
  }

  for (let i = 0; i < points.length; i += 1) {
    for (let j = i + 1; j < points.length; j += 1) {
      const a = points[i];
      const b = points[j];
      const dx = a.x - b.x;
      const dy = a.y - b.y;
      const distance = Math.hypot(dx, dy);

      if (distance < 150) {
        const alpha = (1 - distance / 150) * 0.18;
        ctx.strokeStyle = `rgba(101, 255, 122, ${alpha})`;
        ctx.beginPath();
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(b.x, b.y);
        ctx.stroke();
      }
    }
  }

  for (const point of points) {
    ctx.fillStyle = "rgba(94, 231, 255, 0.45)";
    ctx.fillRect(point.x - 1, point.y - 1, 2, 2);
  }

  raf = window.requestAnimationFrame(draw);
}

function start() {
  window.cancelAnimationFrame(raf);
  if (!prefersReducedMotion.matches) {
    resize();
    draw();
  }
}

window.addEventListener("resize", resize);
prefersReducedMotion.addEventListener("change", start);
start();

const releasePanel = document.querySelector("[data-release-panel]");

if (releasePanel) {
  const releaseStatus = releasePanel.querySelector("[data-release-status]");
  const channels = [
    {
      key: "stable",
      label: "latest stable release",
      manifest: "releases/releases-manifest.json",
    },
    {
      key: "prerelease",
      label: "latest pre-release",
      manifest: "releases/pre-releases-manifest.json",
    },
  ];

  function formatBytes(bytes) {
    if (!Number.isFinite(bytes) || bytes <= 0) return "";
    const units = ["B", "KB", "MB", "GB"];
    let size = bytes;
    let unit = 0;
    while (size >= 1024 && unit < units.length - 1) {
      size /= 1024;
      unit += 1;
    }
    return `${size >= 10 || unit === 0 ? Math.round(size) : size.toFixed(1)} ${units[unit]}`;
  }

  function versionLabel(entry) {
    const version = String(entry.version || entry.tag || "").trim();
    if (!version) return "Download";
    return version.startsWith("v") ? version : `v${version}`;
  }

  function updateReleaseCard(channel, entry) {
    const link = releasePanel.querySelector(`[data-release-link="${channel.key}"]`);
    const version = releasePanel.querySelector(`[data-release-version="${channel.key}"]`);
    if (!link || !version) return false;
    if (!entry) return false;

    const href = String(entry.packageURL || "").trim();
    if (!href) return false;

    const size = formatBytes(Number(entry.packageSize || 0));
    const packageName = String(entry.packageName || "").trim();
    const build = String(entry.build || "").trim();
    const details = [packageName, size, build ? `build ${build}` : ""].filter(Boolean).join(", ");

    link.href = href;
    link.hidden = false;
    version.textContent = versionLabel(entry);
    link.setAttribute("aria-label", `${channel.label} ${versionLabel(entry)}${details ? `, ${details}` : ""}`);
    return true;
  }

  async function loadReleaseManifest(channel) {
    const response = await fetch(channel.manifest, { cache: "no-store" });
    if (!response.ok) {
      throw new Error(`Unable to load ${channel.manifest}`);
    }
    return response.json();
  }

  Promise.allSettled(channels.map(async (channel) => {
    const manifest = await loadReleaseManifest(channel);
    return updateReleaseCard(channel, manifest.latest);
  })).then((results) => {
    const availableCount = results.filter((result) => result.status === "fulfilled" && result.value).length;
    if (!releaseStatus) return;

    if (availableCount === 0) {
      releaseStatus.textContent = "Currently there are no pre-built releases.";
      releaseStatus.hidden = false;
      return;
    }

    releaseStatus.hidden = true;
  });
}

const carousel = document.querySelector("[data-carousel]");
if (carousel) {
  const slides = Array.from(carousel.querySelectorAll("[data-slide]"));
  const dots = Array.from(carousel.querySelectorAll("[data-slide-dot]"));
  const captions = Array.from(carousel.querySelectorAll("[data-caption]"));
  let activeSlide = 0;
  let carouselTimer = 0;
  let userPinnedSlide = false;
  let carouselInView = false;

  function setCarouselSlide(index) {
    activeSlide = (index + slides.length) % slides.length;

    slides.forEach((slide, slideIndex) => {
      slide.classList.toggle("is-active", slideIndex === activeSlide);
    });

    dots.forEach((dot, dotIndex) => {
      const isActive = dotIndex === activeSlide;
      dot.classList.toggle("is-active", isActive);
      dot.setAttribute("aria-selected", String(isActive));
    });

    captions.forEach((caption, captionIndex) => {
      caption.classList.toggle("is-active", captionIndex === activeSlide);
    });
  }

  function stopCarousel() {
    window.clearInterval(carouselTimer);
    carouselTimer = 0;
  }

  function startCarousel() {
    stopCarousel();
    if (prefersReducedMotion.matches || userPinnedSlide || !carouselInView || slides.length < 2) {
      return;
    }

    carouselTimer = window.setInterval(() => {
      setCarouselSlide(activeSlide + 1);
    }, 8400);
  }

  dots.forEach((dot) => {
    dot.addEventListener("click", () => {
      userPinnedSlide = true;
      stopCarousel();
      setCarouselSlide(Number(dot.dataset.slideDot || 0));
    });
  });

  const carouselObserver = new IntersectionObserver(
    (entries) => {
      carouselInView = entries.some((entry) => entry.isIntersecting);
      if (carouselInView) {
        startCarousel();
      } else {
        stopCarousel();
      }
    },
    { threshold: 0.35 }
  );

  carouselObserver.observe(carousel);
  prefersReducedMotion.addEventListener("change", startCarousel);
}

const overlayHosts = Array.from(document.querySelectorAll("[data-overlay-host]"));

function setOverlayOpen(host, isOpen) {
  host.classList.toggle("is-open", isOpen);
  const trigger = host.querySelector(".overlay-trigger");
  if (trigger) {
    trigger.setAttribute("aria-expanded", String(isOpen));
  }
}

function closeOverlays(exceptHost = null) {
  for (const host of overlayHosts) {
    if (host !== exceptHost) {
      setOverlayOpen(host, false);
    }
  }
}

for (const host of overlayHosts) {
  const trigger = host.querySelector(".overlay-trigger");
  if (!trigger) continue;

  trigger.addEventListener("click", (event) => {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) {
      return;
    }

    event.preventDefault();
    event.stopPropagation();

    const isOpen = host.classList.contains("is-open");
    closeOverlays(host);
    setOverlayOpen(host, !isOpen);
  });
}

document.addEventListener("click", (event) => {
  for (const host of overlayHosts) {
    if (!host.contains(event.target)) {
      setOverlayOpen(host, false);
    }
  }
});

document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    closeOverlays();
  }
});
