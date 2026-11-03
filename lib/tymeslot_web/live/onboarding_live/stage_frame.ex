defmodule TymeslotWeb.OnboardingLive.StageFrame do
  @moduledoc """
  The frame the onboarding stage shows the host's booking page in.

  One markup serves both sizes, and the stylesheet (`onboarding.css`) decides
  which parts show:

    * At `lg` and up it is a browser window: a glass card with a top bar
      whose address pill reads `host/username` (the username updating as it
      is typed) and, on the live step, a Live badge.
    * Below `lg` the browser chrome is hidden and the frame is a card at the
      top of the page. A slim strip under it repeats the address and offers
      an Expand button, which opens `StagePreviewModal`.

  The frame is decorative (`aria-hidden`): whatever it shows that matters is
  announced in the layout's live region instead. The Expand button sits
  outside it, so it stays reachable.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  use TymeslotWeb.Components.CoreComponents, only: [action_button: 1, icon: 1]

  alias Phoenix.LiveView.JS

  @doc """
  The address the frame shows for a username: `host/username`, or a
  placeholder name while there is none yet.
  """
  @spec address(String.t(), String.t() | nil) :: String.t()
  def address(host, username) do
    case String.trim(username || "") do
      "" -> "#{host}/#{dgettext("onboarding_wizard", "your-name")}"
      name -> "#{host}/#{name}"
    end
  end

  @doc """
  Renders the frame around the page shown in `inner_block`.
  """
  attr :url, :string, required: true, doc: "the address shown, from `address/2`"
  attr :live, :boolean, default: false, doc: "shows the Live badge in the address pill"
  slot :inner_block, required: true

  @spec frame(map()) :: Phoenix.LiveView.Rendered.t()
  def frame(assigns) do
    assigns = assign(assigns, :address_parts, split_address(assigns.url))

    ~H"""
    <div class="stage-frame-wrap">
      <div class="stage-frame glass-card shadow-glass-lg rounded-token-2xl" aria-hidden="true">
        <div class="stage-frame-bar">
          <div class="stage-frame-address" data-role="stage-address">
            <.icon name="hero-lock-closed-mini" class="w-4 h-4 shrink-0 text-tymeslot-400" />
            <span class="text-token-sm truncate">{@url}</span>
            <.live_badge :if={@live} />
          </div>
        </div>
        <div class="stage-frame-body">
          {render_slot(@inner_block)}
        </div>
      </div>

      <div class="stage-strip">
        <%!-- On a narrow screen the host gives way, never the name. --%>
        <span class="stage-strip-url text-token-sm">
          <span class="truncate">{elem(@address_parts, 0)}</span>
          <span class="shrink-0">{elem(@address_parts, 1)}</span>
        </span>
        <.live_badge :if={@live} />
        <.action_button
          variant={:secondary}
          size={:sm}
          icon="hero-arrows-pointing-out-mini"
          phx-click="expand_stage"
          class="shrink-0"
        >
          {dgettext("onboarding_wizard", "Expand")}
        </.action_button>
      </div>
    </div>
    """
  end

  @doc """
  Scales a page miniature, designed at 400px wide, to the width it is given.

  The `StageScale` hook (`assets/js/hooks/stage_scale.js`) sets
  `--stage-scale` to fill the width (capped at 1.6 from `lg`, at 1 below)
  and reserves the scaled height on this wrapper, since `transform: scale`
  leaves the layout size alone. The hook owns the `style` attribute, so a
  server patch never resets it.
  """
  attr :id, :string, required: true
  slot :inner_block, required: true

  @spec scaled(map()) :: Phoenix.LiveView.Rendered.t()
  def scaled(assigns) do
    ~H"""
    <div
      id={@id}
      class="stage-scale"
      phx-hook="StageScale"
      phx-mounted={JS.ignore_attributes(["style"])}
    >
      <div class="stage-scale-inner" data-role="stage-miniature">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # `host/` and the name after it.
  defp split_address(url) do
    case url |> String.split("/") |> Enum.split(-1) do
      {[], [name]} -> {"", name}
      {host, [name]} -> {Enum.join(host, "/") <> "/", name}
    end
  end

  defp live_badge(assigns) do
    ~H"""
    <span
      class="inline-flex items-center gap-1.5 shrink-0 rounded-token-full bg-turquoise-50 px-2 py-0.5 text-token-xs font-semibold text-turquoise-700"
      data-role="stage-live-badge"
    >
      <span class="w-2 h-2 rounded-token-full bg-turquoise-500 motion-safe:animate-pulse" />
      {dgettext("onboarding_wizard", "Live")}
    </span>
    """
  end
end
