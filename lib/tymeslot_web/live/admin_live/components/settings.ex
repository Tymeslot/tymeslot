defmodule TymeslotWeb.AdminLive.Components.Settings do
  @moduledoc """
  Settings tab. Settings are grouped into sections (Authentication,
  reCAPTCHA, Admin alerts); each section is a single grouped card and each
  row shows the setting name, a short description, and a control on the
  right.

  Boolean settings use the existing two-tag Enabled/Disabled control with
  the active tag rendered as disabled. Score and email settings use a
  small inline form so admins save one value at a time.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.AppSettings
  alias TymeslotWeb.AdminLive.Formatters

  @sections [:authentication, :recaptcha, :payments, :admin_alerts]

  attr :effective_values, :map, required: true

  @spec settings_tab(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_tab(assigns) do
    grouped = Enum.group_by(AppSettings.keys(), &Formatters.section/1)

    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div>
      <h2 class="text-token-2xl font-black text-tymeslot-900 tracking-tight mb-4">
        {gettext("Environment / config")}
      </h2>

      <.info_box variant={:info}>
        {gettext(
          "Changes here take effect immediately and override the matching environment variables and application configuration (e.g. REGISTRATION_ENABLED, PASSWORD_AUTH_ENABLED) for this install."
        )}
      </.info_box>

      <div class="space-y-8 mt-6">
        <.settings_section
          :for={section <- @grouped |> Map.keys() |> Enum.sort_by(&section_order/1)}
          section={section}
          keys={Map.fetch!(@grouped, section)}
          effective_values={@effective_values}
        />
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

      <div class="card-glass !p-0 overflow-hidden divide-y divide-tymeslot-100">
        <.setting_row
          :for={key <- @keys}
          key={key}
          effective_values={@effective_values}
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
      <div class="flex-1 min-w-0">
        <h4 class="text-token-lg font-black text-tymeslot-900 tracking-tight">
          {Formatters.humanise(@key)}
        </h4>
        <p class="mt-1 text-token-sm text-tymeslot-600 font-medium leading-relaxed">
          {Formatters.describe(@key)}
        </p>
        <.recommended_chip :if={Formatters.recommended(@key) != nil} value={Formatters.recommended(@key)} />
      </div>

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

  attr :kind, :atom, required: true
  attr :key, :atom, required: true
  attr :effective, :map, required: true
  attr :disabled, :boolean, default: false

  defp setting_control(%{kind: :boolean} = assigns) do
    ~H"""
    <div
      role="group"
      aria-label={gettext("Set %{name}", name: Formatters.humanise(@key))}
      class="inline-flex p-1 bg-white border-2 border-tymeslot-100 rounded-token-xl shadow-sm gap-1 shrink-0"
    >
      <.setting_tag
        key={@key}
        state="true"
        label={gettext("Enabled")}
        active={@effective.value == true}
        locked={true in @effective.locked_states}
        lock_reason={Formatters.lock_reason(@key, true)}
      />
      <.setting_tag
        key={@key}
        state="false"
        label={gettext("Disabled")}
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
      aria-label={gettext("Set %{name}", name: Formatters.humanise(@key))}
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
      aria-label={gettext("Set %{name}", name: Formatters.humanise(@key))}
    >
      <input type="hidden" name="key" value={Atom.to_string(@key)} />
      <input
        id={"setting-input-#{@key}"}
        type="email"
        name="value"
        value={@effective.value || ""}
        placeholder={gettext("admin@example.com")}
        disabled={@disabled}
        class={text_input_classes("w-64 max-w-full", @disabled)}
      />
      <.action_button
        type="submit"
        variant={:secondary}
        class="!py-1.5 !px-3 !text-token-xs"
        disabled={@disabled}
      >
        {gettext("Save")}
      </.action_button>
    </form>
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
        {gettext("Recommended:")} {Formatters.recommended_label(@value)}
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

  defp section_order(section), do: Enum.find_index(@sections, &(&1 == section)) || 99
end
