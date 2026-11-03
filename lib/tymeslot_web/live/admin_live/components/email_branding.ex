defmodule TymeslotWeb.AdminLive.Components.EmailBranding do
  @moduledoc """
  The two email branding rows on the admin settings page that do not fit the
  generic key-to-control mapping in `Settings`: the brand accent, which needs
  derived preview data, and the email logo, which takes an upload rather than
  a form field.

  `Settings.email_branding_section/1` places them alongside the generic brand
  name row; all three share `SettingRow.row_header/1`, so they look identical.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.AdminLive.Components.SettingRow
  alias TymeslotWeb.AdminLive.Formatters

  # The accent row is its own component rather than a `setting_control` kind
  # because it is the only control needing the derived preview data, and
  # threading that through the generic row would hand it to every other
  # setting too.
  #
  # The control pairs a native swatch picker with the hex text field so an
  # admin can either pick visually or paste a brand hex they already have.
  # Only the hex form ever writes to `AppSettings`: the swatch is
  # preview-only and pushes its pick into `accent_draft`, which the hex
  # field's `value` mirrors. Letting both forms write the same setting used
  # to race - the swatch's autosave-on-blur could land after the hex form's
  # stale submit and null the setting out. Routing every persist through the
  # one hex form removes the second writer instead of narrowing the window.
  attr :effective, :map, required: true
  attr :stock_accent, :string, required: true
  attr :accent_preview, :map, default: nil
  attr :accent_draft, :string, default: nil

  @spec brand_accent_row(map()) :: Phoenix.LiveView.Rendered.t()
  def brand_accent_row(assigns) do
    assigns =
      assigns
      |> assign(:current, assigns.effective.value || assigns.stock_accent)
      |> assign(:hex_value, assigns.accent_draft || assigns.effective.value || "")

    ~H"""
    <div class="px-8 py-6 flex items-start justify-between gap-6 flex-wrap sm:flex-nowrap">
      <SettingRow.row_header key={:email_brand_accent} />

      <div class="flex flex-col items-end gap-2 shrink-0">
        <form
          id="admin-setting-form-email_brand_accent"
          phx-change="preview_accent"
          class="flex items-center gap-2"
        >
          <input
            id="setting-swatch-email_brand_accent"
            type="color"
            name="value"
            value={@current}
            phx-debounce="blur"
            aria-label={dgettext("dashboard_admin", "Pick a colour")}
            aria-describedby="email-brand-accent-feedback"
            class="h-9 w-12 rounded-token-lg border-2 border-tymeslot-100 bg-white p-1 cursor-pointer"
          />
        </form>

        <form
          id="admin-setting-hex-form-email_brand_accent"
          phx-submit="save_setting"
          class="flex items-center gap-2"
          aria-label={
            dgettext("dashboard_admin", "Set %{name}", name: Formatters.humanise(:email_brand_accent))
          }
        >
          <input type="hidden" name="key" value="email_brand_accent" />
          <input
            id="setting-input-email_brand_accent"
            type="text"
            name="value"
            value={@hex_value}
            placeholder={@stock_accent}
            spellcheck="false"
            aria-describedby="email-brand-accent-feedback"
            class={SettingRow.text_input_classes("w-32 font-mono", false)}
          />
          <.action_button type="submit" variant={:secondary} size={:sm}>
            {dgettext("dashboard_admin", "Save")}
          </.action_button>
        </form>

        <div id="email-brand-accent-feedback" aria-live="polite">
          <.contrast_warning
            :if={@accent_preview != nil and @accent_preview.low_contrast?}
            ratio={@accent_preview.contrast}
          />
        </div>
      </div>
    </div>
    """
  end

  # The email logo is not a plain form field: it takes an upload, so it is
  # its own row rather than a `setting_control` kind, reading the LiveView's
  # upload state and the currently stored logo from its own attrs.
  #
  # The visible control is a plain file input, not `live_file_input`: the hook
  # rasterises whatever the admin picked to a PNG in the browser and hands the
  # result to the uploader via `this.upload/2`. That keeps SVG and WebP sources
  # working without a rasteriser on the server, and means the only bytes that
  # ever reach the server are a PNG — which `Branding.store_logo/1` re-validates,
  # because a client-side conversion is a convenience, not a trust boundary.
  attr :logo_url, :string, default: nil
  attr :upload, :map, required: true
  attr :errors, :list, default: []
  # What the file picker offers, not what is uploaded: the browser rasterises
  # whatever the admin picked to a PNG before it reaches the server.
  attr :accept, :string, default: "image/png,image/jpeg,image/webp,image/svg+xml"
  # 2x the 150px the email displays the logo at, so it stays sharp on retina
  # without carrying a needlessly large attachment on every send.
  attr :render_width, :integer, default: 300
  # A 300px-wide PNG lands far under this; the cap is a backstop against a
  # client that ignores the hook and posts something else entirely. Sourced
  # from the caller's `@logo_max_bytes`, the single place the limit is
  # declared - it also feeds `allow_upload/3` and the hook's own client-side
  # size guard, so there is exactly one number to keep in sync.
  attr :max_bytes, :integer, required: true

  @spec email_logo_row(map()) :: Phoenix.LiveView.Rendered.t()
  def email_logo_row(assigns) do
    ~H"""
    <div class="px-8 py-6 flex items-start justify-between gap-6 flex-wrap sm:flex-nowrap">
      <SettingRow.row_header key={:email_logo_path} />

      <div class="flex flex-col items-end gap-3 shrink-0">
        <div
          :if={@logo_url}
          class="flex items-center gap-3 px-4 py-3 rounded-token-xl bg-tymeslot-50 border-2 border-tymeslot-100"
        >
          <img
            src={@logo_url}
            alt={dgettext("dashboard_admin", "Current email logo")}
            class="h-10 w-auto max-w-[150px] object-contain"
          />
          <.action_button variant={:danger_soft} size={:sm} phx-click="remove_email_logo">
            {dgettext("dashboard_admin", "Remove")}
          </.action_button>
        </div>

        <form id="admin-email-logo-form" phx-change="validate_email_logo">
          <%!--
            The uploader input is present but hidden. `this.upload/2` in the hook
            resolves the uploader by looking up upload inputs in the DOM by name,
            so it has to exist even though the admin never interacts with it.
          --%>
          <.live_file_input upload={@upload} class="hidden" />

          <label class={[
            button_classes(:secondary, :sm),
            "focus-within:outline-hidden focus-within:ring-2 focus-within:ring-turquoise-500 focus-within:ring-offset-2"
          ]}>
            <.icon name="hero-arrow-up-tray-mini" class="w-4 h-4" />
            {if @logo_url,
              do: dgettext("dashboard_admin", "Replace"),
              else: dgettext("dashboard_admin", "Upload")}
            <input
              id="email-logo-picker"
              type="file"
              accept={@accept}
              class="sr-only"
              phx-hook="EmailLogoUpload"
              phx-update="ignore"
              aria-describedby="email-logo-errors"
              data-upload-name={@upload.name}
              data-render-width={@render_width}
              data-max-bytes={@max_bytes}
            />
          </label>
        </form>

        <div id="email-logo-errors" aria-live="polite">
          <p
            :for={message <- @errors}
            class="max-w-[16rem] text-token-xs font-bold text-red-600 text-right"
          >
            {message}
          </p>
        </div>
      </div>
    </div>
    """
  end

  attr :ratio, :float, required: true

  defp contrast_warning(assigns) do
    ~H"""
    <p class="flex items-start gap-1.5 max-w-[16rem] text-token-xs font-bold text-amber-700 text-right">
      <.icon name="hero-exclamation-triangle-mini" class="w-4 h-4 shrink-0 mt-px" />
      <span>
        {dgettext(
          "dashboard_admin",
          "White button text on this colour has a contrast of only %{ratio}:1. Buttons may be hard to read.",
          ratio: :erlang.float_to_binary(@ratio, decimals: 1)
        )}
      </span>
    </p>
    """
  end
end
