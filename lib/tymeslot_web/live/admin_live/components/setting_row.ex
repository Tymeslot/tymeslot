defmodule TymeslotWeb.AdminLive.Components.SettingRow do
  @moduledoc """
  The pieces every row on the admin settings page shares, whichever module
  renders its control: the left-hand header (name, description, recommended
  value, pinned note) and the classes of the inline text inputs.

  Shared so the email branding rows (`EmailBranding`), which render their own
  controls, stay visually identical to the generic ones in `Settings`.
  """

  use TymeslotWeb, :html
  use Gettext, backend: TymeslotWeb.Gettext

  alias TymeslotWeb.AdminLive.Formatters

  # The left-hand half of a settings row: name, description, and the
  # recommended-value chip where one applies.
  attr :key, :atom, required: true
  attr :muted, :boolean, default: false
  attr :pinned_by, :string, default: nil

  # The pinned note sits outside the muted wrapper so it stays legible on a
  # pinned setting whose value is off.
  @spec row_header(map()) :: Phoenix.LiveView.Rendered.t()
  def row_header(assigns) do
    ~H"""
    <div class="flex-1 basis-full sm:basis-0 min-w-0">
      <div class={["transition-opacity", @muted && "opacity-60"]}>
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
      <p
        :if={@pinned_by}
        id={"setting-pinned-#{@key}"}
        class="mt-3 flex items-start gap-1.5 text-token-xs font-bold text-tymeslot-700"
      >
        <.icon name="hero-lock-closed-mini" class="w-4 h-4 mt-px shrink-0 text-tymeslot-500" />
        <span>{Formatters.pinned_reason(@pinned_by)}</span>
      </p>
    </div>
    """
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

  @doc """
  Shared classes for the inline text inputs (score, email, text, accent hex).
  Disabled inputs get a muted background and tone-down on text, mirroring the
  locked boolean-tag styling so disabled controls are visually unambiguous.
  """
  @spec text_input_classes(String.t(), boolean()) :: [String.t()]
  def text_input_classes(size_classes, disabled?) do
    [
      "px-3 py-1.5 rounded-token-lg border-2 text-token-sm font-bold focus:outline-hidden focus:ring-2 focus:ring-turquoise-500 focus:border-turquoise-500",
      size_classes,
      if(disabled?,
        do: "bg-tymeslot-50 border-tymeslot-100 text-tymeslot-300 cursor-not-allowed",
        else: "border-tymeslot-100 text-tymeslot-900"
      )
    ]
  end
end
