defmodule TymeslotWeb.AdminLive.Components.Settings do
  @moduledoc """
  Settings tab: a single grouped card under an "Environment / config"
  heading. Each row shows the setting name, a description with the
  recommended value, and an Enabled/Disabled two-tag control.

  The active tag mirrors the effective value (regardless of whether it
  comes from the DB, config, or the built-in default) and is rendered
  disabled so re-clicks don't fire spurious writes.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.AppSettings
  alias TymeslotWeb.AdminLive.Formatters

  attr :effective_values, :map, required: true

  @spec settings_tab(map()) :: Phoenix.LiveView.Rendered.t()
  def settings_tab(assigns) do
    ~H"""
    <div>
      <h2 class="text-2xl font-black text-tymeslot-900 tracking-tight mb-4">
        {gettext("Environment / config")}
      </h2>

      <.info_box variant={:info}>
        {gettext(
          "Changes here take effect immediately and override the matching environment variables and application configuration (e.g. REGISTRATION_ENABLED, PASSWORD_AUTH_ENABLED) for this install."
        )}
      </.info_box>

      <div class="card-glass !p-0 overflow-hidden divide-y divide-tymeslot-100">
        <.setting_row
          :for={key <- AppSettings.keys()}
          key={key}
          effective={Map.fetch!(@effective_values, key)}
        />
      </div>
    </div>
    """
  end

  attr :key, :atom, required: true
  attr :effective, :map, required: true

  defp setting_row(assigns) do
    ~H"""
    <div class="px-8 py-6 flex items-start justify-between gap-6 flex-wrap sm:flex-nowrap">
      <div class="flex-1 min-w-0">
        <h3 class="text-lg font-black text-tymeslot-900 tracking-tight">
          {Formatters.humanise(@key)}
        </h3>
        <p class="mt-1 text-sm text-tymeslot-600 font-medium leading-relaxed">
          {Formatters.describe(@key)}
        </p>
        <.recommended_chip :if={Formatters.recommended(@key) != nil} value={Formatters.recommended(@key)} />
      </div>

      <div
        role="group"
        aria-label={gettext("Set %{name}", name: Formatters.humanise(@key))}
        class="inline-flex p-1 bg-white border-2 border-tymeslot-100 rounded-token-xl shadow-sm gap-1 flex-shrink-0"
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
    </div>
    """
  end

  attr :value, :boolean, required: true

  defp recommended_chip(assigns) do
    ~H"""
    <div class="mt-3 inline-flex items-center gap-1.5 px-2.5 py-1 rounded-token-lg bg-turquoise-50 border border-turquoise-100">
      <.icon name="hero-check-badge-mini" class="w-4 h-4 text-turquoise-600" />
      <span class="text-xs font-bold text-turquoise-700">
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
        "px-3 py-1.5 rounded-token-lg text-xs font-black uppercase tracking-wider transition-all",
        cond do
          @active -> "bg-turquoise-600 text-white shadow-md shadow-turquoise-200/40 cursor-default"
          @locked -> "text-tymeslot-300 cursor-not-allowed"
          true -> "text-tymeslot-500 hover:bg-tymeslot-50 hover:text-tymeslot-900 cursor-pointer"
        end
      ]}
    >
      {@label}
    </button>
    """
  end
end
