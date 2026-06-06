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

const carousel = document.querySelector("[data-carousel]");
if (carousel) {
  const slides = Array.from(carousel.querySelectorAll("[data-slide]"));
  const dots = Array.from(carousel.querySelectorAll("[data-slide-dot]"));
  const captions = Array.from(carousel.querySelectorAll("[data-caption]"));
  const previousButton = carousel.querySelector("[data-carousel-previous]");
  const nextButton = carousel.querySelector("[data-carousel-next]");
  const carouselFrame = carousel.querySelector(".screenshot-frame") || carousel;
  const autoplayDelay = 8400;
  let activeSlide = 0;
  let carouselTimer = 0;
  let userPinnedSlide = false;
  let carouselInView = false;
  let transitionToken = 0;

  function setCarouselSlide(index) {
    activeSlide = (index + slides.length) % slides.length;
    const activeSlideId = slides[activeSlide]?.dataset.slide || String(activeSlide);
    if (slides[activeSlide]) {
      slides[activeSlide].loading = "eager";
    }

    slides.forEach((slide, slideIndex) => {
      slide.classList.toggle("is-active", slideIndex === activeSlide);
    });

    dots.forEach((dot) => {
      const isActive = dot.dataset.slideDot === activeSlideId;
      dot.classList.toggle("is-active", isActive);
      dot.setAttribute("aria-selected", String(isActive));
    });

    captions.forEach((caption) => {
      caption.classList.toggle("is-active", caption.dataset.caption === activeSlideId);
    });
  }

  function shouldAutoplay() {
    return !prefersReducedMotion.matches && !userPinnedSlide && carouselInView && !document.hidden && slides.length > 1;
  }

  async function prepareSlide(index) {
    const slide = slides[(index + slides.length) % slides.length];
    if (!slide) return;

    slide.loading = "eager";

    if (slide.complete && slide.naturalWidth > 0) {
      return;
    }

    if (typeof slide.decode === "function") {
      try {
        await slide.decode();
      } catch (_error) {
        // A failed decode should not trap the carousel; the browser can still try to paint the image.
      }
    }
  }

  async function advanceCarousel() {
    stopCarousel();
    if (!shouldAutoplay()) {
      return;
    }

    const token = transitionToken + 1;
    transitionToken = token;
    const nextSlide = activeSlide + 1;
    await prepareSlide(nextSlide);

    if (transitionToken !== token || !shouldAutoplay()) {
      return;
    }

    setCarouselSlide(nextSlide);
    startCarousel();
  }

  function stopCarousel() {
    window.clearTimeout(carouselTimer);
    carouselTimer = 0;
  }

  function startCarousel() {
    stopCarousel();
    if (!shouldAutoplay()) {
      return;
    }

    carouselTimer = window.setTimeout(advanceCarousel, autoplayDelay);
  }

  dots.forEach((dot) => {
    dot.addEventListener("click", (event) => {
      event.preventDefault();
      userPinnedSlide = true;
      transitionToken += 1;
      stopCarousel();
      const slideIndex = slides.findIndex((slide) => slide.dataset.slide === dot.dataset.slideDot);
      setCarouselSlide(slideIndex >= 0 ? slideIndex : 0);
    });
  });

  function setPinnedSlide(index) {
    userPinnedSlide = true;
    transitionToken += 1;
    stopCarousel();
    setCarouselSlide(index);
  }

  previousButton?.addEventListener("click", (event) => {
    event.preventDefault();
    setPinnedSlide(activeSlide - 1);
  });

  nextButton?.addEventListener("click", (event) => {
    event.preventDefault();
    setPinnedSlide(activeSlide + 1);
  });

  const carouselObserver = new IntersectionObserver(
    (entries) => {
      carouselInView = entries.some((entry) => entry.isIntersecting && entry.intersectionRatio >= 0.35);
      if (carouselInView) {
        startCarousel();
      } else {
        transitionToken += 1;
        stopCarousel();
      }
    },
    { threshold: [0, 0.35, 0.7] }
  );

  carouselObserver.observe(carouselFrame);
  prefersReducedMotion.addEventListener("change", startCarousel);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      transitionToken += 1;
      stopCarousel();
    } else {
      startCarousel();
    }
  });
}

const copyButtons = Array.from(document.querySelectorAll("[data-copy-value]"));

async function copyTextToClipboard(text) {
  if (navigator.clipboard && window.isSecureContext) {
    await navigator.clipboard.writeText(text);
    return;
  }

  const textArea = document.createElement("textarea");
  textArea.value = text;
  textArea.setAttribute("readonly", "");
  textArea.style.position = "fixed";
  textArea.style.left = "-9999px";
  document.body.appendChild(textArea);
  textArea.select();
  document.execCommand("copy");
  document.body.removeChild(textArea);
}

copyButtons.forEach((button) => {
  button.addEventListener("click", async () => {
    const originalLabel = button.textContent;

    try {
      await copyTextToClipboard(button.dataset.copyValue || "");
      button.textContent = "Copied";
      button.classList.add("is-copied");
    } catch (_error) {
      button.textContent = "Select";
    }

    window.setTimeout(() => {
      button.textContent = originalLabel;
      button.classList.remove("is-copied");
    }, 1400);
  });
});

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
