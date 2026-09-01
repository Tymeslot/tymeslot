defmodule TymeslotWeb.AdminLive.Components.Settings do
  @moduledoc """
  The settings tabs. Each tab renders the sections
  `TymeslotWeb.AdminLive.Tabs` assigns it, in the order declared there; each
  section is a single grouped card and each row shows the setting name, a
  short description, and a control on the right.

  Boolean settings use the two-tag Enabled/Disabled control with the active
  tag rendered as disabled. Score, email, text, and colour settings use a
  small inline form so admins save one value at a time.

  Email branding is rendered by its own `email_branding_section/1` rather than
  through the generic loop. Its logo row takes an upload instead of a form
  field, and its accent row needs derived preview data, so routing it through
  the generic components would mean handing that state to every other setting
  as well. The two share `row_header/1` with the generic rows, so both look
  identical. The section's assigns come from what `TymeslotWeb.AdminLive`
  builds in `load_data/1`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.AppSettings
  alias TymeslotWeb.AdminLive.Formatters
  alias TymeslotWeb.AdminLive.Tabs

  attr :tab, :atom, required: true
  attr :effective_values, :map, required: true
  attr :email_logo_url, :string, default: nil
  attr :upload, :map, required: true
  attr :logo_errors, :list, default: []
  attr :stock_accent, :string, required: true
  attr :accent_preview, :map, default: nil
  attr :accent_draft, :string, default: nil
  attr :max_logo_bytes, :integer, required: true

  @spec settings_tab(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_tab(assigns) do
    grouped = Enum.group_by(AppSettings.keys(), &Formatters.section/1)

    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div>
      <%!-- The tab bar already names this page on screen, so a visible heading
           would just repeat the active pill. Screen readers still need
           something to land on. --%>
      <h2 class="sr-only">{Tabs.name(@tab)}</h2>

      <.info_box variant={:info}>
        {dgettext(
          "dashboard_admin",
          "Changes here take effect immediately and override the matching environment variables and application configuration (e.g. REGISTRATION_ENABLED, PASSWORD_AUTH_ENABLED) for this install."
        )}
      </.info_box>

      <%!-- Branding is still rendered by its own component rather than the
           generic loop, so its upload and preview state reaches only the
           section that uses it. --%>
      <div class="space-y-8 mt-6">
        <%= for section <- Tabs.sections(@tab) do %>
          <%= if section == :email_branding do %>
            <.email_branding_section
              effective_values={@effective_values}
              email_logo_url={@email_logo_url}
              upload={@upload}
              logo_errors={@logo_errors}
              stock_accent={@stock_accent}
              accent_preview={@accent_preview}
              accent_draft={@accent_draft}
              max_logo_bytes={@max_logo_bytes}
            />
          <% else %>
            <.settings_section
              section={section}
              keys={Map.fetch!(@grouped, section)}
              effective_values={@effective_values}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :section, :atom, required: true
  attr :keys, :list, required: true
  attr :effective_values, :map, required: true

  defp settings_section(assigns) do
    ~H"""
    <section>
      <h3 class="text-token-sm font-black uppercase tracking-wider text-tymeslot-500 mb-3 px-1">
        {Formatters.section_label(@section)}
      </h3>

      <div class="card-glass p-0! overflow-hidden divide-y divide-tymeslot-100">
        <.setting_row :for={key <- @keys} key={key} effective_values={@effective_values} />
      </div>
    </section>
    """
  end

  # Email branding is the one section that does not fit the generic
  # key-to-control mapping: the logo takes an upload rather than a form field,
  # and the accent needs preview data no other row has a use for. It gets its
  # own section so that state stops travelling through components that ignore
  # it. A new branding setting has to be added here explicitly.
  attr :effective_values, :map, required: true
  attr :email_logo_url, :string, default: nil
  attr :upload, :map, required: true
  attr :logo_errors, :list, default: []
  attr :stock_accent, :string, required: true
  attr :accent_preview, :map, default: nil
  attr :accent_draft, :string, default: nil
  attr :max_logo_bytes, :integer, required: true

  defp email_branding_section(assigns) do
    ~H"""
    <section>
      <h3 class="text-token-sm font-black uppercase tracking-wider text-tymeslot-500 mb-3 px-1">
        {Formatters.section_label(:email_branding)}
      </h3>

      <div class="card-glass p-0! overflow-hidden divide-y divide-tymeslot-100">
        <.setting_row key={:email_brand_name} effective_values={@effective_values} />
        <.brand_accent_row
          effective={Map.fetch!(@effective_values, :email_brand_accent)}
          stock_accent={@stock_accent}
          accent_preview={@accent_preview}
          accent_draft={@accent_draft}
        />
        <.email_logo_row
          logo_url={@email_logo_url}
          upload={@upload}
          errors={@logo_errors}
          max_bytes={@max_logo_bytes}
        />
      </div>
    </section>
    """
  end

  attr :key, :atom, required: true
  attr :effective_values, :map, required: true

  defp setting_row(assigns) do
    effective = Map.fetch!(assigns.effective_values, assigns.key)
    kind = Formatters.kind(assigns.key)

    disabled =
      parent_disabled?(assigns.key, assigns.effective_values) or
        own_value_off?(kind, effective)

    assigns =
      assigns
      |> assign(:effective, effective)
      |> assign(:kind, kind)
      |> assign(:disabled, disabled)

    ~H"""
    <div class={[
      "px-8 py-6 flex items-start justify-between gap-6 flex-wrap sm:flex-nowrap transition-opacity",
      @disabled && "opacity-60"
    ]}>
      <.row_header key={@key} />

      <.setting_control kind={@kind} key={@key} effective={@effective} disabled={@disabled} />
    </div>
    """
  end

  # The left-hand half of a settings row: name, description, and the
  # recommended-value chip where one applies. Shared so the branding rows,
  # which render their own controls, stay visually identical to the generic
  # ones.
  attr :key, :atom, required: true

  defp row_header(assigns) do
    ~H"""
    <div class="flex-1 min-w-0">
      <h4 class="text-token-lg font-black text-tymeslot-900 tracking-tight">
        {Formatters.humanise(@key)}
      </h4>
      <p class="mt-1 text-token-sm text-tymeslot-600 font-medium leading-relaxed">
        {Formatters.describe(@key)}
      </p>
      <.recommended_chip
        :if={Formatters.recommended(@key) != nil}
        value={Formatters.recommended(@key)}
      />
    </div>
    """
  end

  # True when this setting depends on a parent setting that is currently `false`.
  defp parent_disabled?(key, effective_values) do
    case Formatters.depends_on(key) do
      nil -> false
      parent -> Map.fetch!(effective_values, parent).value == false
    end
  end

  # True when this is a boolean setting that is currently in its "off" state,
  # so the row should read as disabled/inactive at a glance.
  defp own_value_off?(:boolean, %{value: false}), do: true
  defp own_value_off?(_kind, _effective), do: false

  attr :kind, :atom, required: true
  attr :key, :atom, required: true
  attr :effective, :map, required: true
  attr :disabled, :boolean, default: false

  defp setting_control(%{kind: :boolean} = assigns) do
    ~H"""
    <div
      role="group"
      aria-label={dgettext("dashboard_admin", "Set %{name}", name: Formatters.humanise(@key))}
      class="inline-flex p-1 bg-white border-2 border-tymeslot-100 rounded-token-xl shadow-sm gap-1 shrink-0"
    >
      <.setting_tag
        key={@key}
        state="true"
        label={dgettext("dashboard_admin", "Enabled")}
        active={@effective.value == true}
        locked={true in @effective.locked_states}
        lock_reason={Formatters.lock_reason(@key, true)}
      />
      <.setting_tag
        key={@key}
        state="false"
        label={dgettext("dashboard_admin", "Disabled")}
        active={@effective.value == false}
        locked={false in @effective.locked_states}
        lock_reason={Formatters.lock_reason(@key, false)}
      />
    </div>
    """
  end

  defp setting_control(%{kind: :score} = assigns) do
    ~H"""
    <form
      id={"admin-setting-form-#{@key}"}
      phx-change="save_setting"
      phx-submit="save_setting"
      class="flex items-center gap-2 shrink-0"
      aria-label={dgettext("dashboard_admin", "Set %{name}", name: Formatters.humanise(@key))}
    >
      <input type="hidden" name="key" value={Atom.to_string(@key)} />
      <input
        id={"setting-input-#{@key}"}
        type="number"
        name="value"
        min="0"
        max="1"
        step="0.05"
        phx-debounce="blur"
        value={format_score(@effective.value)}
        disabled={@disabled}
        class={text_input_classes("w-24 text-center", @disabled)}
      />
    </form>
    """
  end

  defp setting_control(%{kind: :email} = assigns) do
    ~H"""
    <form
      id={"admin-setting-form-#{@key}"}
      phx-submit="save_setting"
      class="flex items-center gap-2 shrink-0 max-w-full"
      aria-label={dgettext("dashboard_admin", "Set %{name}", name: Formatters.humanise(@key))}
    >
      <input type="hidden" name="key" value={Atom.to_string(@key)} />
      <input
        id={"setting-input-#{@key}"}
        type="email"
        name="value"
        value={@effective.value || ""}
        placeholder={dgettext("dashboard_admin", "admin@example.com")}
        disabled={@disabled}
        class={text_input_classes("w-64 max-w-full", @disabled)}
      />
      <.action_button
        type="submit"
        variant={:secondary}
        class="py-1.5! px-3! text-token-xs!"
        disabled={@disabled}
      >
        {dgettext("dashboard_admin", "Save")}
      </.action_button>
    </form>
    """
  end

  defp setting_control(%{kind: :text} = assigns) do
    ~H"""
    <form
      id={"admin-setting-form-#{@key}"}
      phx-submit="save_setting"
      class="flex items-center gap-2 shrink-0 max-w-full"
      aria-label={dgettext("dashboard_admin", "Set %{name}", name: Formatters.humanise(@key))}
    >
      <input type="hidden" name="key" value={Atom.to_string(@key)} />
      <input
        id={"setting-input-#{@key}"}
        type="text"
        name="value"
        value={@effective.value || ""}
        placeholder={AppSettings.default_for(@key)}
        disabled={@disabled}
        class={text_input_classes("w-64 max-w-full", @disabled)}
      />
      <.action_button
        type="submit"
        variant={:secondary}
        class="py-1.5! px-3! text-token-xs!"
        disabled={@disabled}
      >
        {dgettext("dashboard_admin", "Save")}
      </.action_button>
    </form>
    """
  end

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

  defp brand_accent_row(assigns) do
    assigns =
      assigns
      |> assign(:current, assigns.effective.value || assigns.stock_accent)
      |> assign(:hex_value, assigns.accent_draft || assigns.effective.value || "")

    ~H"""
    <div class="px-8 py-6 flex items-start justify-between gap-6 flex-wrap sm:flex-nowrap">
      <.row_header key={:email_brand_accent} />

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
            class={text_input_classes("w-32 font-mono", false)}
          />
          <.action_button type="submit" variant={:secondary} class="py-1.5! px-3! text-token-xs!">
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

  defp email_logo_row(assigns) do
    ~H"""
    <div class="px-8 py-6 flex items-start justify-between gap-6 flex-wrap sm:flex-nowrap">
      <.row_header key={:email_logo_path} />

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
          <button
            type="button"
            phx-click="remove_email_logo"
            class="text-token-xs font-black uppercase tracking-wider text-red-600 hover:text-red-700 cursor-pointer"
          >
            {dgettext("dashboard_admin", "Remove")}
          </button>
        </div>

        <form id="admin-email-logo-form" phx-change="validate_email_logo">
          <%!--
            The uploader input is present but hidden. `this.upload/2` in the hook
            resolves the uploader by looking up upload inputs in the DOM by name,
            so it has to exist even though the admin never interacts with it.
          --%>
          <.live_file_input upload={@upload} class="hidden" />

          <label class="inline-flex items-center gap-2 px-3 py-1.5 rounded-token-lg border-2 border-tymeslot-100 bg-white text-token-xs font-black uppercase tracking-wider text-tymeslot-700 hover:bg-tymeslot-50 cursor-pointer focus-within:outline-hidden focus-within:ring-2 focus-within:ring-turquoise-500 focus-within:ring-offset-2">
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

  # Shared classes for the score and email text inputs. Disabled inputs get a
  # muted background and tone-down on text, mirroring the locked boolean-tag
  # styling so disabled controls are visually unambiguous.
  defp text_input_classes(size_classes, disabled?) do
    [
      "px-3 py-1.5 rounded-token-lg border-2 text-token-sm font-bold focus:outline-hidden focus:ring-2 focus:ring-turquoise-500 focus:border-turquoise-500",
      size_classes,
      if(disabled?,
        do: "bg-tymeslot-50 border-tymeslot-100 text-tymeslot-300 cursor-not-allowed",
        else: "border-tymeslot-100 text-tymeslot-900"
      )
    ]
  end

  attr :value, :boolean, required: true

  defp recommended_chip(assigns) do
    ~H"""
    <div class="mt-3 inline-flex items-center gap-1.5 px-2.5 py-1 rounded-token-lg bg-turquoise-50 border border-turquoise-100">
      <.icon name="hero-check-badge-mini" class="w-4 h-4 text-turquoise-600" />
      <span class="text-token-xs font-bold text-turquoise-700">
        {dgettext("dashboard_admin", "Recommended:")} {Formatters.recommended_label(@value)}
      </span>
    </div>
    """
  end

  attr :key, :atom, required: true
  attr :state, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, required: true
  attr :locked, :boolean, default: false
  attr :lock_reason, :string, default: nil

  # NOTE: the param is named `state`, not `value`, because Phoenix LiveView's
  # client-side serialisation reads the button's native `value` IDL property
  # and would overwrite `phx-value-value` with the empty string.
  defp setting_tag(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_setting"
      phx-value-key={@key}
      phx-value-state={@state}
      disabled={@active or @locked}
      aria-pressed={@active}
      aria-disabled={@locked}
      title={@lock_reason}
      class={[
        "px-3 py-1.5 rounded-token-lg text-token-xs font-black uppercase tracking-wider transition-all",
        cond do
          @active -> "bg-turquoise-600 text-white shadow-md shadow-turquoise-200/40 cursor-default"
          @locked -> "bg-tymeslot-50 text-tymeslot-300 cursor-not-allowed opacity-60"
          true -> "text-tymeslot-500 hover:bg-tymeslot-50 hover:text-tymeslot-900 cursor-pointer"
        end
      ]}
    >
      {@label}
    </button>
    """
  end

  # Renders a float as a fixed two-decimal string so the input value stays
  # human-readable (0.30 instead of 0.3000000000000001).
  defp format_score(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 2)
  end

  defp format_score(nil), do: ""
end
