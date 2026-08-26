(() => {
  const header = document.querySelector(".site-header");
  const menuToggle = document.querySelector(".mobile-menu-toggle");
  const mobileNavigation = document.querySelector("#mobile-navigation");
  const closeButton = document.querySelector("[data-menu-close]");
  const sectionLinks = [...document.querySelectorAll("[data-nav-section]")];
  const linkedSectionIds = new Set(sectionLinks.map((link) => link.dataset.navSection));
  const sections = [...document.querySelectorAll("main section[id]")]
    .filter((section) => linkedSectionIds.has(section.id));
  let sectionUpdateQueued = false;
  let scrollSettledTimer;

  const setMenuOpen = (open, restoreFocus = false) => {
    document.body.classList.toggle("mobile-nav-open", open);
    menuToggle.setAttribute("aria-expanded", String(open));
    menuToggle.setAttribute("aria-label", open ? "Close navigation" : "Open navigation");
    mobileNavigation.setAttribute("aria-hidden", String(!open));
    mobileNavigation.inert = !open;

    if (open) {
      window.setTimeout(() => {
        if (menuToggle.getAttribute("aria-expanded") === "true") {
          mobileNavigation.querySelector("a")?.focus({ preventScroll: true });
        }
      }, 50);
    } else if (restoreFocus) {
      menuToggle.focus({ preventScroll: true });
    }
  };

  const setActiveSection = (sectionId) => {
    sectionLinks.forEach((link) => {
      const active = link.dataset.navSection === sectionId;
      link.classList.toggle("is-active", active);
      if (active) {
        link.setAttribute("aria-current", "location");
      } else {
        link.removeAttribute("aria-current");
      }
    });
  };

  const updateActiveSection = () => {
    const activationLine = header.getBoundingClientRect().height + 8;
    let activeSection = sections[0]?.id;

    if (window.scrollY + window.innerHeight >= document.documentElement.scrollHeight - 2) {
      activeSection = sections.at(-1)?.id;
    } else {
      sections.forEach((section) => {
        if (section.getBoundingClientRect().top <= activationLine) {
          activeSection = section.id;
        }
      });
    }

    if (activeSection) {
      setActiveSection(activeSection);
    }
    sectionUpdateQueued = false;
  };

  const queueSectionUpdate = () => {
    if (!sectionUpdateQueued) {
      sectionUpdateQueued = true;
      requestAnimationFrame(updateActiveSection);
    }
  };

  menuToggle.addEventListener("click", () => {
    setMenuOpen(menuToggle.getAttribute("aria-expanded") !== "true");
  });
  closeButton.addEventListener("click", () => setMenuOpen(false, true));

  sectionLinks.forEach((link) => {
    link.addEventListener("click", () => {
      setActiveSection(link.dataset.navSection);
      if (link.closest(".mobile-nav-panel")) {
        setMenuOpen(false);
      }
    });
  });

  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && menuToggle.getAttribute("aria-expanded") === "true") {
      setMenuOpen(false, true);
    }
  });

  window.addEventListener("scroll", () => {
    queueSectionUpdate();
    window.clearTimeout(scrollSettledTimer);
    scrollSettledTimer = window.setTimeout(queueSectionUpdate, 120);
  }, { passive: true });
  window.addEventListener("scrollend", queueSectionUpdate);
  window.addEventListener("resize", () => {
    if (window.innerWidth > 700 && menuToggle.getAttribute("aria-expanded") === "true") {
      setMenuOpen(false);
    }
    queueSectionUpdate();
  });
  window.addEventListener("hashchange", queueSectionUpdate);
  window.addEventListener("load", queueSectionUpdate);
  queueSectionUpdate();
})();
