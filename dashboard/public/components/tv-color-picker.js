/* <tv-color-picker></tv-color-picker>

   The popover a lane's colour is chosen in. Custom colours keep to a fixed saturation and a
   band of lightness, so a lane's colour stays readable on the dark board; a
   hex outside that is snapped into it.

   open(anchor, colors, color) shows it under `anchor`, offering `colors`,
   with `color` the one the lane has now. It is a popover, so a click outside
   it or Escape closes it, as Cancel does. The caller owns the list of
   colours; a custom colour is only reported, and the caller decides whether
   to offer it next time.

   Events (bubbling and composed):
     color-input   detail { color }  the custom colour was changed; the caller
                   may show it as a preview until color-pick or color-cancel
     color-pick    detail { color, custom }  a colour was chosen, from the
                   grid or as a custom colour, and the picker closed
     color-cancel  the picker closed without a colour being chosen */

import { attachTemplate, loadTemplate } from "./template.js";

const template = await loadTemplate("tv-color-picker.html");

/* The bounds of a custom colour, in HSL. */
const saturation = 70;
const minLightness = 55;
const maxLightness = 80;

export class TvColorPicker extends HTMLElement {
  #anchor = null;
  /* The lane's colour when the picker opened. */
  #original = null;
  #picked = false;
  #hue = 0;
  #lightness = minLightness;

  #swatches;
  #more;
  #custom;
  #hueInput;
  #hueValue;
  #lightInput;
  #lightValue;
  #preview;
  #hex;

  #place = () => this.#placeUnder(this.#anchor);

  constructor() {
    super();
    const root = attachTemplate(this, template);

    this.#swatches = root.querySelector(".swatches");
    this.#more = root.querySelector(".more");
    this.#custom = root.querySelector(".custom");
    this.#hueInput = root.querySelector(".hue");
    this.#hueValue = root.querySelector(".hue-value");
    this.#lightInput = root.querySelector(".light");
    this.#lightValue = root.querySelector(".light-value");
    this.#preview = root.querySelector(".preview");
    this.#hex = root.querySelector(".hex");

    this.#swatches.addEventListener("click", (event) => {
      const swatch = event.target.closest(".swatch");
      if (swatch) {
        this.#pick(swatch.dataset.color, false);
      } else if (event.target.closest(".more")) {
        this.#toggleCustom();
      }
    });
    this.#hueInput.addEventListener("input", () => {
      this.#setCustom(Number(this.#hueInput.value), this.#lightness);
    });
    this.#lightInput.addEventListener("input", () => {
      this.#setCustom(this.#hue, Number(this.#lightInput.value));
    });
    this.#hex.addEventListener("change", () => this.#onHex());
    this.#hex.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        this.#onHex();
      }
    });
    this.shadowRoot
      .querySelector(".cancel")
      .addEventListener("click", () => this.hidePopover());
    this.shadowRoot
      .querySelector(".use")
      .addEventListener("click", () => this.#pick(this.#color(), true));

    this.addEventListener("toggle", (event) => this.#onToggle(event));
  }

  connectedCallback() {
    this.popover = "auto";
    this.setAttribute("role", "dialog");
    this.setAttribute("aria-label", "Lane color");
  }

  get isOpen() {
    return this.matches(":popover-open");
  }

  /* `anchor` is also the popover's source, so clicking it again does not
     light-dismiss the picker first; the caller can then close it instead. */
  open(anchor, colors, color) {
    this.#anchor = anchor;
    this.#original = color;
    this.#picked = false;

    this.#swatches.replaceChildren(
      ...colors.map((c) => this.#renderSwatch(c, c === color)),
      this.#more,
    );
    this.#showCustom(false);

    this.showPopover({ source: anchor });
    this.#place();
    this.#swatches.querySelector('[aria-checked="true"], .more').focus();
  }

  #renderSwatch(color, checked) {
    const swatch = document.createElement("button");
    swatch.type = "button";
    swatch.className = "swatch";
    swatch.setAttribute("role", "radio");
    swatch.setAttribute("aria-label", color);
    swatch.setAttribute("aria-checked", checked);
    swatch.dataset.color = color;
    swatch.style.background = color;
    return swatch;
  }

  /* Closing it takes back the preview by reporting the lane's own colour. */
  #toggleCustom() {
    const open = this.#custom.hidden;
    this.#showCustom(open);
    if (open) {
      const { h, l } = toHsl(this.#original);
      this.#setCustom(h, l);
      this.#hueInput.focus();
    } else {
      this.#emit("color-input", { color: this.#original });
    }
  }

  #showCustom(open) {
    this.#custom.hidden = !open;
    this.#more.setAttribute("aria-expanded", open);
    for (const swatch of this.#swatches.querySelectorAll(".swatch")) {
      swatch.setAttribute(
        "aria-checked",
        !open && swatch.dataset.color === this.#original,
      );
    }
  }

  #setCustom(hue, lightness) {
    this.#hue = Math.round(hue) % 360;
    this.#lightness = Math.min(
      maxLightness,
      Math.max(minLightness, Math.round(lightness)),
    );
    const color = this.#color();

    this.#hueInput.value = this.#hue;
    this.#hueValue.textContent = `${this.#hue}°`;
    this.#lightInput.value = this.#lightness;
    this.#lightValue.textContent = `${this.#lightness}%`;
    this.#lightInput.style.setProperty(
      "--track",
      `linear-gradient(to right, hsl(${this.#hue}, ${saturation}%, ${minLightness}%), hsl(${this.#hue}, ${saturation}%, ${maxLightness}%))`,
    );
    this.#preview.style.background = color;
    this.#hex.value = color.toUpperCase();
    this.#emit("color-input", { color });
  }

  #onHex() {
    const value = this.#hex.value.trim().replace(/^#?/, "#");
    if (!/^#[0-9a-f]{6}$/i.test(value)) {
      this.#hex.value = this.#color().toUpperCase();
      return;
    }
    const { h, l } = toHsl(value.toLowerCase());
    this.#setCustom(h, l);
  }

  #color() {
    return toHex(this.#hue, saturation, this.#lightness);
  }

  #pick(color, custom) {
    this.#picked = true;
    this.hidePopover();
    this.#emit("color-pick", { color, custom });
  }

  /* Closing by Cancel, Escape or a click outside all cancel. While open,
     the picker follows its swatch as the page scrolls. */
  #onToggle(event) {
    if (event.newState === "open") {
      window.addEventListener("scroll", this.#place, true);
      window.addEventListener("resize", this.#place);
      return;
    }

    window.removeEventListener("scroll", this.#place, true);
    window.removeEventListener("resize", this.#place);
    if (!this.#picked) {
      this.#emit("color-cancel", {});
    }
    this.#anchor = null;
  }

  #placeUnder(anchor) {
    if (!anchor) {
      return;
    }
    const box = anchor.getBoundingClientRect();
    const width = this.offsetWidth;
    const left = Math.max(
      8,
      Math.min(box.right - width, window.innerWidth - width - 8),
    );
    this.style.left = `${left}px`;
    this.style.top = `${box.bottom + 12}px`;
  }

  #emit(type, detail) {
    this.dispatchEvent(
      new CustomEvent(type, { bubbles: true, composed: true, detail }),
    );
  }
}

/* HSL with saturation and lightness in percent, to "#rrggbb". */
function toHex(h, s, l) {
  const sat = s / 100;
  const light = l / 100;
  const a = sat * Math.min(light, 1 - light);
  const channel = (n) => {
    const k = (n + h / 30) % 12;
    const value = light - a * Math.max(-1, Math.min(k - 3, 9 - k, 1));
    return Math.round(value * 255)
      .toString(16)
      .padStart(2, "0");
  };
  return `#${channel(0)}${channel(8)}${channel(4)}`;
}

/* "#rrggbb" to its hue in degrees and lightness in percent. */
function toHsl(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255);
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  const d = max - min;
  let h = 0;
  if (d !== 0) {
    if (max === r) {
      h = ((g - b) / d) % 6;
    } else if (max === g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
  }
  return { h: (h * 60 + 360) % 360, l: l * 100 };
}

customElements.define("tv-color-picker", TvColorPicker);
