defmodule TymeslotWeb.Themes.Shared.ConfirmationText do
  @moduledoc """
  What a confirmation step is announcing, decided once for every theme.

  Each theme words its own headline per status ("Meeting Confirmed!",
  "You're All Set!"), but which status applies, and the sentences that name
  the organiser, must not drift between themes. A booking held for the host's
  approval is announced as a request, never as a confirmed meeting; the
  approval check runs before the reschedule check, because a gated reschedule
  re-enters the hold (see `Tymeslot.Bookings.Reschedule`).

  A booking waiting for its attendee to confirm their email address
  (`:check_inbox`) is checked before either: a gated approval booking is held
  for verification first, and only becomes a request once verified. Owner
  preview never reaches it, as a simulated booking skips verification.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.MeetingState
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Helpers.LocaleFormat
  alias TymeslotWeb.Themes.Shared.ApprovalDisplay
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers
  alias TymeslotWeb.Themes.Shared.Voice

  @type status :: :check_inbox | :held | :rescheduled | :confirmed

  @doc "Which of the four outcomes the confirmation step describes."
  @spec status(map()) :: status()
  def status(assigns) do
    cond do
      check_inbox?(assigns) -> :check_inbox
      ApprovalDisplay.awaiting_approval?(assigns) -> :held
      assigns[:is_rescheduling] -> :rescheduled
      true -> :confirmed
    end
  end

  @doc """
  Whether the step offers what follows a booking: the calendar file and the
  hints to reschedule or withdraw. A booking still waiting for its attendee
  to confirm their email offers neither, as it is not a booking yet.
  """
  @spec follow_ups?(map()) :: boolean()
  def follow_ups?(assigns), do: status(assigns) != :check_inbox

  @doc """
  Whether the booking still waits on someone, its attendee's email or the
  host's approval, so the step's badge and the line naming the address must
  not read as a confirmation.
  """
  @spec pending?(map()) :: boolean()
  def pending?(assigns), do: status(assigns) in [:check_inbox, :held]

  @doc "The icon for the step's badge: an envelope, a clock, or a tick."
  @spec badge_icon(map()) :: String.t()
  def badge_icon(assigns) do
    case status(assigns) do
      :check_inbox -> "hero-envelope"
      :held -> "hero-clock"
      _confirmed_or_rescheduled -> "hero-check"
    end
  end

  @doc """
  The headline while the booking waits for its attendee to confirm their
  email, in the voice of the theme with key `theme_key` where it has one.
  """
  @spec check_inbox_headline(Catalog.theme_key() | nil) :: String.t()
  def check_inbox_headline(theme_key \\ nil) do
    Voice.line(Voice.of(theme_key), :check_inbox, %{}, fn ->
      dgettext("booking_confirmation", "Check your inbox")
    end)
  end

  @doc """
  The sentence under the check-your-inbox headline: where the link went and
  until when the time is held, in the voice of the theme with key
  `theme_key` where it has one.

  Names the booking's own `verification_deadline_at` as a date and time on
  the attendee's clock (`user_timezone`), not the length of the hold: the
  hold is capped at the meeting's start, so a booking made close to it is
  held for less. The date is always there, as on the verify page, so a hold
  running past midnight never reads as a time already gone.

  A booking on a group meeting type is a seat (`:check_inbox_message_seat`):
  what is held is the booker's place, as the seat's verification email says,
  not the time, which other attendees may share.
  """
  @spec check_inbox_message(map(), Catalog.theme_key() | nil) :: String.t()
  def check_inbox_message(assigns, theme_key \\ nil) do
    email = assigns[:email]
    by_deadline = deadline_text(assigns[:verification_deadline_at], assigns[:user_timezone])
    bindings = %{email: email, by_deadline: by_deadline}
    voice = Voice.of(theme_key)

    if MeetingTypes.group_type?(assigns[:meeting_type]) do
      Voice.line(voice, :check_inbox_message_seat, bindings, fn ->
        dgettext(
          "booking_confirmation",
          "We have sent a link to %{email}. Click it by %{by_deadline} to confirm your booking. Until then your place is held for you.",
          email: email,
          by_deadline: by_deadline
        )
      end)
    else
      Voice.line(voice, :check_inbox_message, bindings, fn ->
        dgettext(
          "booking_confirmation",
          "We have sent a link to %{email}. Click it by %{by_deadline} to confirm your booking. Until then the time is held for you.",
          email: email,
          by_deadline: by_deadline
        )
      end)
    end
  end

  # A booking awaiting verification always carries its deadline
  # (`EmailVerification.gate_attributes/2`), so there is no fallback.
  defp deadline_text(%DateTime{} = deadline, timezone) do
    deadline
    |> LocalizationHelpers.format_meeting_datetime(timezone)
    |> LocaleFormat.with_article(:none, Gettext.get_locale(TymeslotWeb.Gettext))
  end

  @doc """
  The sentence under a held booking's headline, in the voice of the theme
  with key `theme_key` where it has one.

  The confirmed and rescheduled sentences compose "with %{name}" onto a fixed
  stem ("your meeting with Jane"). A request cannot take that fragment ("your
  request with Jane" is the wrong preposition, and mistranslates in every
  other locale), so the held case is its own self-contained sentence.
  """
  @spec held_message(String.t() | nil, map() | nil, Catalog.theme_key() | nil) :: String.t()
  def held_message(name, organizer_profile, theme_key \\ nil) do
    voice = Voice.of(theme_key)

    case Profiles.display_name(organizer_profile) do
      organizer_name when is_binary(organizer_name) and organizer_name != "" ->
        bindings = %{name: name, organizer_name: organizer_name}

        Voice.line(voice, :held_message_named, bindings, fn ->
          dgettext(
            "booking_confirmation",
            "%{name}, your request to %{organizer_name} has been sent.",
            name: name,
            organizer_name: organizer_name
          )
        end)

      _no_organizer_name ->
        Voice.line(voice, :held_message, %{name: name}, fn ->
          dgettext("booking_confirmation", "%{name}, your request has been sent.", name: name)
        end)
    end
  end

  @doc """
  "with <organiser>", for the confirmed and rescheduled sentences, in the
  voice of the theme with key `theme_key` where it has one; empty when there
  is no organiser name to give.
  """
  @spec organizer_fragment(map() | nil, Catalog.theme_key() | nil) :: String.t()
  def organizer_fragment(organizer_profile, theme_key \\ nil)
  def organizer_fragment(nil, _theme_key), do: ""

  def organizer_fragment(organizer_profile, theme_key) do
    case Profiles.display_name(organizer_profile) do
      nil ->
        ""

      name ->
        Voice.line(Voice.of(theme_key), :organizer_fragment, %{name: name}, fn ->
          dgettext("booking_confirmation", "with %{name}", name: name)
        end)
    end
  end

  defp check_inbox?(assigns) do
    MeetingState.awaiting_verification_status?(assigns[:meeting_status]) and
      assigns[:owner_preview] != true
  end
end
