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
