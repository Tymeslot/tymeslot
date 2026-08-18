/**
 * EmailLogoUpload hook
 *
 * Rasterises the logo an admin picks into a PNG before it is uploaded, so the
 * server never has to decode SVG or WebP and the inbox always receives a
 * format every mail client renders. Gmail and Outlook render neither SVG nor
 * (in Outlook's case) WebP, so uploading the original file would produce a
 * logo that previews correctly in the admin UI and then breaks in the email.
 *
 * The browser already has decoders for every format we accept, which is why
 * the conversion happens here rather than behind a system dependency like
 * librsvg or ImageMagick in the release image.
 *
 * This is a convenience, not a trust boundary: the server re-validates that
 * what arrives is a real PNG. A client that skips the hook entirely just gets
 * its upload rejected.
 */

// Height ceiling in rendered pixels. The email displays the logo 150px wide,
// so a very tall logo is scaled to fit rather than dominating the header.
const MAX_RENDER_HEIGHT = 240;

// Fallback dimensions for an SVG whose intrinsic size the browser reports as
// zero (Firefox does this for SVGs with only a viewBox and no width/height).
const SVG_FALLBACK = { width: 300, height: 100 };

export const EmailLogoUpload = {
  mounted() {
    this.onChange = this.handleChange.bind(this);
    this.el.addEventListener("change", this.onChange);
  },

  destroyed() {
    this.el.removeEventListener("change", this.onChange);
  },

  async handleChange(event) {
    const file = event.target.files && event.target.files[0];
    if (!file) return;

    const uploadName = this.el.dataset.uploadName || "email_logo";
    const renderWidth = parseInt(this.el.dataset.renderWidth, 10) || 300;
    const maxBytes = parseInt(this.el.dataset.maxBytes, 10);

    // Reject an oversized source before it is base64-encoded and decoded by
    // the browser: `readAsDataURL` pays that cost up front regardless of how
    // small the rendered canvas ends up being.
    if (maxBytes && file.size > maxBytes) {
      this.pushEvent("email_logo_too_large", {});
      this.el.value = "";
      return;
    }

    try {
      const png = await rasterise(file, renderWidth);
      this.upload(uploadName, [png]);
    } catch (error) {
      console.error("Email logo conversion failed:", error);
      this.pushEvent("email_logo_conversion_failed", {});
    } finally {
      // Clear the input so re-picking the same file fires `change` again,
      // which matters when the first attempt failed.
      this.el.value = "";
    }
  },
};

async function rasterise(file, renderWidth) {
  const image = await loadImage(file);
  const { width, height } = targetSize(image, file, renderWidth);

  const canvas = document.createElement("canvas");
  canvas.width = width;
  canvas.height = height;

  // No background fill: a logo with transparency should stay transparent, and
  // the email canvas behind it is a warm off-white rather than pure white.
  const context = canvas.getContext("2d");
  context.drawImage(image, 0, 0, width, height);

  const blob = await canvasToBlob(canvas);
  return new File([blob], "email-logo.png", { type: "image/png" });
}

// The picked file is read as a data: URL rather than an object URL. The app's
// Content-Security-Policy sets `img-src 'self' data: https:`, which does not
// include blob:, so an object URL is blocked before the image ever decodes.
// A data: URL is permitted, is same-origin for canvas purposes (so the canvas
// is never tainted), and costs only the base64 overhead on a file we already
// cap at 2 MB.
function loadImage(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();

    reader.onerror = () => reject(new Error("Could not read the selected file"));

    reader.onload = () => {
      const image = new Image();

      image.onload = () => resolve(image);

      image.onerror = () =>
        reject(new Error(`Could not decode ${file.type || "file"}`));

      // Loading an SVG through <img> does not execute scripts inside it, so
      // this stays safe for a file we have deliberately not sanitised.
      image.src = reader.result;
    };

    reader.readAsDataURL(file);
  });
}

function targetSize(image, file, renderWidth) {
  const isVector = file.type === "image/svg+xml";
  const naturalWidth = image.naturalWidth || (isVector ? SVG_FALLBACK.width : 0);
  const naturalHeight = image.naturalHeight || (isVector ? SVG_FALLBACK.height : 0);

  if (!naturalWidth || !naturalHeight) {
    throw new Error("Image reported no intrinsic size");
  }

  // A vector scales to whatever we ask for; a raster is never upscaled, since
  // enlarging it would add bytes without adding detail.
  const width = isVector ? renderWidth : Math.min(renderWidth, naturalWidth);
  const aspect = naturalHeight / naturalWidth;
  const height = width * aspect;

  if (height > MAX_RENDER_HEIGHT) {
    return {
      width: Math.round(MAX_RENDER_HEIGHT / aspect),
      height: MAX_RENDER_HEIGHT,
    };
  }

  return { width: Math.round(width), height: Math.round(height) };
}

function canvasToBlob(canvas) {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (blob) {
        resolve(blob);
      } else {
        reject(new Error("Canvas produced no PNG data"));
      }
    }, "image/png");
  });
}

export default EmailLogoUpload;
