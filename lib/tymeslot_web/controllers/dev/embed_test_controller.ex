defmodule TymeslotWeb.Dev.EmbedTestController do
  @moduledoc """
  Dev-only controller that serves an interactive embed test page at `/embed-test`.

  The page renders four embed scenarios side-by-side (unconstrained, constrained,
  small fixed height, popup) and lets you switch usernames and themes on the fly.
  It loads `/embed.js` from the running dev server, so `mix phx.server` must be
  running.

  ## Testing with an external HTML file

  If you want to test embedding from a standalone HTML file, you must **serve it
  over HTTP** rather than opening it directly as a `file://` URL. Opening as
  `file://` gives the page a `null` origin, which is not covered by the dev CSP
  `frame-ancestors` allowlist (`http://localhost:* http://127.0.0.1:*`), so the
  iframe is blocked.

  A sample page lives at `/tmp/tymeslot-embed-test.html` and covers three
  `data-min-height` scenarios: default (400px), explicit 600px, and the 200px
  floor. Use it to validate the attribute end-to-end.

  Serve it from a local HTTP server:

      python3 -m http.server 8080 -d /tmp

  Then open `http://localhost:8080/tymeslot-embed-test.html` in your browser. The
  page origin matches `http://localhost:*` in the CSP and the embed works as
  expected.
  """
  use TymeslotWeb, :controller

  alias Phoenix.HTML
  alias TymeslotWeb.Endpoint

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    username =
      (params["username"] || "demo")
      |> HTML.html_escape()
      |> HTML.safe_to_string()

    base_url = Endpoint.url()

    html(conn, """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8" />
      <meta name="viewport" content="width=device-width, initial-scale=1" />
      <title>Embed Test Page</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body { font-family: system-ui, -apple-system, sans-serif; background: #f8fafc; color: #1e293b; padding: 24px; }
        h1 { font-size: 24px; margin-bottom: 8px; }
        .subtitle { color: #64748b; margin-bottom: 32px; }
        .controls { background: white; border: 1px solid #e2e8f0; border-radius: 12px; padding: 20px; margin-bottom: 32px; display: flex; gap: 16px; flex-wrap: wrap; align-items: end; }
        .control-group { display: flex; flex-direction: column; gap: 4px; }
        .control-group label { font-size: 13px; font-weight: 600; color: #475569; }
        .control-group input, .control-group select { padding: 8px 12px; border: 1px solid #cbd5e1; border-radius: 8px; font-size: 14px; }
        .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
        .card { background: white; border: 1px solid #e2e8f0; border-radius: 12px; overflow: hidden; }
        .card-header { padding: 16px 20px; border-bottom: 1px solid #e2e8f0; background: #f8fafc; }
        .card-header h2 { font-size: 16px; }
        .card-header p { font-size: 13px; color: #64748b; margin-top: 4px; }
        .card-body { padding: 20px; position: relative; }
        .embed-container { border: 2px dashed #e2e8f0; border-radius: 8px; overflow: hidden; }
        .size-label { position: absolute; top: 28px; right: 28px; background: #1e293b; color: white; font-size: 11px; padding: 2px 8px; border-radius: 4px; z-index: 10; pointer-events: none; }
        @media (max-width: 768px) { .grid { grid-template-columns: 1fr; } }
      </style>
    </head>
    <body>
      <h1>Embed Test Page</h1>
      <p class="subtitle">Test how the booking widget looks at different sizes. Simulates embedding on an external site.</p>

      <div class="controls">
        <div class="control-group">
          <label>Username</label>
          <input type="text" id="username" value="#{username}" />
        </div>
        <div class="control-group">
          <label>Theme</label>
          <select id="theme">
            <option value="">User default</option>
            <option value="1">Quill (1)</option>
            <option value="2">Rhythm (2)</option>
          </select>
        </div>
        <div class="control-group">
          <label>Custom Height (px)</label>
          <input type="number" id="custom-height" value="400" min="200" max="2000" step="50" />
        </div>
        <div class="control-group">
          <label>Min Height (px)</label>
          <input type="number" id="min-height" value="" min="200" max="2000" step="50" placeholder="400 (default)" />
        </div>
        <div class="control-group">
          <label>&nbsp;</label>
          <button onclick="reload()" style="padding: 8px 20px; background: #14b8a6; color: white; border: none; border-radius: 8px; cursor: pointer; font-weight: 600;">Reload All</button>
        </div>
      </div>

      <div class="grid">
        <div class="card">
          <div class="card-header">
            <h2>Unconstrained (default)</h2>
            <p>No height limit — iframe grows to fit content</p>
          </div>
          <div class="card-body">
            <span class="size-label">auto height</span>
            <div class="embed-container" id="embed-full"></div>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <h2>Constrained Height</h2>
            <p>Container has a fixed max-height — should scroll</p>
          </div>
          <div class="card-body">
            <span class="size-label" id="constrained-label">400px max</span>
            <div class="embed-container" id="embed-constrained" style="max-height: 400px; overflow: hidden;"></div>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <h2>Small (400px)</h2>
            <p>Tight space — content must be scrollable</p>
          </div>
          <div class="card-body">
            <span class="size-label">400px fixed</span>
            <div class="embed-container" id="embed-small" style="height: 400px; overflow: hidden;"></div>
          </div>
        </div>

        <div class="card">
          <div class="card-header">
            <h2>Popup Mode</h2>
            <p>Click the button to test modal embed</p>
          </div>
          <div class="card-body" style="text-align: center; padding: 40px;">
            <button id="popup-btn" style="padding: 12px 28px; background: #14b8a6; color: white; border: none; border-radius: 12px; cursor: pointer; font-size: 16px; font-weight: 600; box-shadow: 0 4px 12px rgba(20,184,166,0.3);">
              Book a Meeting
            </button>
          </div>
        </div>
      </div>

      <script src="#{base_url}/embed.js"></script>
      <script>
        function getUsername() {
          return document.getElementById('username').value || 'demo';
        }

        function getOptions() {
          var theme = document.getElementById('theme').value;
          var opts = {};
          if (theme) opts.theme = theme;
          return opts;
        }

        function reload() {
          const user = getUsername();
          const opts = getOptions();
          const customHeight = document.getElementById('custom-height').value;
          const minHeightVal = document.getElementById('min-height').value;

          // Update constrained container
          const constrained = document.getElementById('embed-constrained');
          constrained.style.maxHeight = customHeight + 'px';
          constrained.style.overflow = 'hidden';
          document.getElementById('constrained-label').textContent = customHeight + 'px max';

          // Reset small container overflow too
          document.getElementById('embed-small').style.overflow = 'hidden';

          // Set min-height on unconstrained container if specified
          const fullContainer = document.getElementById('embed-full');
          if (minHeightVal) {
            fullContainer.setAttribute('data-min-height', minHeightVal);
            opts.minHeight = minHeightVal;
          } else {
            fullContainer.removeAttribute('data-min-height');
          }

          // Clear and re-embed all containers
          ['embed-full', 'embed-constrained', 'embed-small'].forEach(id => {
            TymeslotBooking.embed('#' + id, user, opts);
          });
        }

        // Initial load
        document.addEventListener('DOMContentLoaded', function() {
          // Wait for embed script to load
          const interval = setInterval(function() {
            if (window.TymeslotBooking) {
              clearInterval(interval);
              reload();

              document.getElementById('popup-btn').onclick = function() {
                TymeslotBooking.open(getUsername(), getOptions());
              };
            }
          }, 100);
        });
      </script>
    </body>
    </html>
    """)
  end
end
