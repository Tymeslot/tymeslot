defmodule TymeslotWeb.EmbedBlockedHTML do
  @moduledoc """
  Renders the embed-unavailable notice page (see `EmbedBlockedController`).

  Deliberately self-contained: a full HTML document with inline styles and no
  app chrome, so it stays tiny and renders the same inside any embedding site.
  When a `parent_origin` is known, a small inline script posts
  `tymeslot-embed-blocked` to the embedder; the message type is a public
  cross-repo contract (see the WordPress plugin's `embed-detect.js`). The script
  is static and reads the origin from a `data-` attribute, so nothing is
  interpolated into JavaScript.
  """
  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  attr :csp_nonce, :string, default: nil
  attr :parent_origin, :string, default: nil

  @spec index(map()) :: Phoenix.LiveView.Rendered.t()
  def index(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="robots" content="noindex, nofollow" />
        <title>{dgettext("embed", "Booking unavailable")}</title>
        <style nonce={@csp_nonce}>
          html, body { margin: 0; height: 100%; }
          body {
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100%;
            padding: 24px;
            box-sizing: border-box;
            background: #f8fafc;
            color: #334155;
            font-family: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
            text-align: center;
          }
          .ts-card { max-width: 440px; }
          .ts-card h1 { margin: 0 0 8px; font-size: 18px; font-weight: 600; color: #0f172a; }
          .ts-card p { margin: 0; font-size: 14px; line-height: 1.5; color: #64748b; }
        </style>
      </head>
      <body data-parent-origin={@parent_origin}>
        <main class="ts-card">
          <h1>{dgettext("embed", "This booking page can’t be embedded here")}</h1>
          <p>
            {dgettext(
              "embed",
              "The organiser hasn’t authorised this website to show their booking page."
            )}
          </p>
        </main>
        <script :if={@parent_origin} nonce={@csp_nonce}>
          (function () {
            try {
              var origin = document.body.getAttribute("data-parent-origin");
              if (origin) {
                window.parent.postMessage({ type: "tymeslot-embed-blocked" }, origin);
              }
            } catch (e) {}
          })();
        </script>
      </body>
    </html>
    """
  end
end
