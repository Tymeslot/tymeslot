defmodule TymeslotWeb.AdminLive.Components.Settings do
  @moduledoc """
  The settings tabs. Each tab renders the sections
  `TymeslotWeb.AdminLive.Tabs` assigns it, in the order declared there; each
  section is a single grouped card and each row shows the setting name, a
  short description, and a control on the right.

  Boolean settings use the two-tag Enabled/Disabled control with the active
  tag rendered as disabled. Score, email, text, colour, and locale settings
  use a small inline form so admins save one value at a time.

  A setting fixed by an environment variable (`effective.env_var` set) keeps
  its current value on screen but its control is disabled, and its header
  names the variable.

  Email branding is rendered by its own `email_branding_section/1` rather than
  through the generic loop. Its logo row takes an upload instead of a form
  field, and its accent row needs derived preview data, so routing it through
  the generic components would mean handing that state to every other setting
  as well. Those two rows live in `EmailBranding`; every row, generic or not,
  shares `SettingRow.row_header/1`, so they all look identical. The section's
  assigns come from what `TymeslotWeb.AdminLive` builds in `load_data/1`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.AppSettings
  alias TymeslotWeb.AdminLive.Components.EmailBranding
  alias TymeslotWeb.AdminLive.Components.LocaleSetting
  alias TymeslotWeb.AdminLive.Components.SettingRow
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
          "Changes here take effect immediately. A setting fixed by an environment variable, such as REGISTRATION_ENABLED, is greyed out and changes only when you edit that variable and restart Tymeslot."
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

      <.card padding={:none} class="overflow-hidden divide-y divide-tymeslot-100">
        <.admin_setting_row :for={key <- @keys} key={key} effective_values={@effective_values} />
      </.card>
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

      <.card padding={:none} class="overflow-hidden divide-y divide-tymeslot-100">
        <.admin_setting_row key={:email_brand_name} effective_values={@effective_values} />
        <EmailBranding.brand_accent_row
          effective={Map.fetch!(@effective_values, :email_brand_accent)}
          stock_accent={@stock_accent}
          accent_preview={@accent_preview}
          accent_draft={@accent_draft}
        />
        <EmailBranding.email_logo_row
          logo_url={@email_logo_url}
          upload={@upload}
          errors={@logo_errors}
          max_bytes={@max_logo_bytes}
        />
      </.card>
    </section>
    """
  end

  attr :key, :atom, required: true
  attr :effective_values, :map, required: true

  defp admin_setting_row(assigns) do
    effective = Map.fetch!(assigns.effective_values, assigns.key)
    kind = Formatters.kind(assigns.key)

    # Two states that used to share one flag, which made every switched-off
    # boolean render its own toggle at 60% opacity - reading as "you cannot
    # click this" on the one control that is the only way back on.
    #
    # `disabled` is genuine inertness: a dependent setting whose parent is
    # off, or a setting an environment variable fixes, has a control that
    # really is unusable. `muted` is merely "this setting is not doing
    # anything at the moment", which is worth saying in the description but
    # must never be said about a live control. A pinned setting is live, so
    # pinning alone does not mute it.
    parent_off = parent_disabled?(assigns.key, assigns.effective_values)
    disabled = parent_off or effective.env_var != nil
    muted = parent_off or own_value_off?(kind, effective)

    assigns =
      assigns
      |> assign(:effective, effective)
      |> assign(:kind, kind)
      |> assign(:disabled, disabled)
      |> assign(:muted, muted)

    ~H"""
    <div class="px-8 py-6 flex items-start justify-between gap-6 flex-wrap sm:flex-nowrap">
      <SettingRow.row_header key={@key} muted={@muted} pinned_by={@effective.env_var} />

      <.setting_control kind={@kind} key={@key} effective={@effective} disabled={@disabled} />
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

  # A pinned setting's reason outranks the lockout one: removing the
  # variable is the only way to change it at all.
  defp tag_lock_reason(_key, _state, %{env_var: var}) when is_binary(var),
    do: Formatters.pinned_reason(var)

  defp tag_lock_reason(key, state, _effective), do: Formatters.lock_reason(key, state)

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
        locked={@effective.env_var != nil or true in @effective.locked_states}
        lock_reason={tag_lock_reason(@key, true, @effective)}
      />
      <.setting_tag
        key={@key}
        state="false"
        label={dgettext("dashboard_admin", "Disabled")}
        active={@effective.value == false}
        locked={@effective.env_var != nil or false in @effective.locked_states}
        lock_reason={tag_lock_reason(@key, false, @effective)}
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
        class={SettingRow.text_input_classes("w-24 text-center", @disabled)}
      />
    </form>
    """
  end

  defp setting_control(%{kind: kind} = assigns) when kind in [:email, :text] do
    assigns =
      assigns
      |> assign(:input_type, Atom.to_string(kind))
      |> assign(:placeholder, text_placeholder(kind, assigns.key))

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
        type={@input_type}
        name="value"
        value={@effective.value || ""}
        placeholder={@placeholder}
        disabled={@disabled}
        class={SettingRow.text_input_classes("w-64 max-w-full", @disabled)}
      />
      <.action_button
        type="submit"
        variant={:secondary}
        size={:sm}
        disabled={@disabled}
      >
        {dgettext("dashboard_admin", "Save")}
      </.action_button>
    </form>
    """
  end

  defp setting_control(%{kind: :locale} = assigns) do
    ~H"""
    <LocaleSetting.locale_control key={@key} effective={@effective} disabled={@disabled} />
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
      aria-pressed={to_string(@active)}
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

  defp text_placeholder(:email, _key), do: dgettext("dashboard_admin", "admin@example.com")
  defp text_placeholder(:text, key), do: AppSettings.default_for(key)

  # Renders a float as a fixed two-decimal string so the input value stays
  # human-readable (0.30 instead of 0.3000000000000001).
  defp format_score(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 2)
  end

  defp format_score(nil), do: ""
end
