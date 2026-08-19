defmodule TymeslotWeb.Themes.Shared.Components.ApprovalNotice do
  @moduledoc """
  Tells a booking visitor that this meeting type needs the host's approval.

  Two variants of one fact, sized for where they appear:

    * `pill/1` — a small marker beside a meeting type in a list, or beside the
      time being picked. Answers "is there a catch?" at a glance.
    * `block/1` — a fuller sentence on the booking form and the thank-you
      screen, where the visitor is deciding or has just committed and deserves
      the whole rule rather than a hint of it.

  ## Why this exists at all

  A visitor who picks a time expects to have booked it. On a gated meeting
  type they have not, and the moment they find that out should be *before*
  they submit, not in an email afterwards. Every stage of the flow therefore
  carries the notice, escalating in detail as the commitment grows.

  Follows the shared-component pattern of `MeetingDetails`: neutral class
  names here, visual treatment in each theme's own CSS, because the themes are
  self-contained and share no tokens.

  Callers pass `requires_approval` through `Tymeslot.Meetings.Approval.required?/1`
  rather than reading the field, because SaaS demo organisers supply meeting
  types as plain maps that have no such key.
  """

  use Phoenix.Component
  use Gettext, backend: TymeslotWeb.Gettext

  import TymeslotWeb.Components.CoreComponents, only: [icon: 1]

  attr :class, :string, default: nil

  @doc "The compact marker, for lists and headers."
  @spec pill(map()) :: Phoenix.LiveView.Rendered.t()
  def pill(assigns) do
    ~H"""
    <span class={["approval-pill", @class]} data-testid="approval-pill">
      <.icon name="hero-hand-raised-micro" class="approval-pill-icon" />
      <span class="approval-pill-text">{dgettext("booking", "Needs approval")}</span>
    </span>
    """
  end

  attr :organizer_name, :string, default: nil
  attr :stage, :atom, default: :before, values: [:before, :after]
  attr :class, :string, default: nil

  @doc """
  The fuller notice, for the booking form and the thank-you screen.

  `stage` decides the tense: `:before` warns what will happen, `:after`
  describes what just did.
  """
  @spec block(map()) :: Phoenix.LiveView.Rendered.t()
  def block(assigns) do
    ~H"""
    <div
      class={["approval-notice", "approval-notice-#{@stage}", @class]}
      data-testid="approval-notice"
    >
      <div class="approval-notice-icon-wrapper">
        <.icon name="hero-hand-raised" class="approval-notice-icon" />
      </div>
      <div class="approval-notice-body">
        <p class="approval-notice-title">{title(assigns)}</p>
        <p class="approval-notice-text">{text(assigns)}</p>
      </div>
    </div>
    """
  end

  defp title(%{stage: :after}), do: dgettext("booking", "Not confirmed yet")
  defp title(_assigns), do: dgettext("booking", "This booking needs approval")

  defp text(%{stage: :after} = assigns) do
    dgettext(
      "booking",
      "%{organizer} still has to accept this time. We'll email you either way, and the slot is held for you until then.",
      organizer: host(assigns)
    )
  end

  defp text(assigns) do
    dgettext(
      "booking",
      "%{organizer} confirms each booking personally, so submitting this sends a request rather than booking the time outright. The slot is held for you while they decide.",
      organizer: host(assigns)
    )
  end

  # The organiser's name is not always resolvable at every stage; falling back
  # keeps the sentence grammatical rather than leaving a gap where a name goes.
  defp host(%{organizer_name: name}) when is_binary(name) and name != "", do: name
  defp host(_assigns), do: dgettext("booking", "The host")
end
