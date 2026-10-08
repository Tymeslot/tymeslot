defmodule TymeslotWeb.Themes.Shared.ConfirmationText do
  @moduledoc """
  What a confirmation step is announcing, decided once for every theme.

  Each theme words its own headline per status ("Meeting Confirmed!",
  "You're All Set!"), but which status applies, and the sentences that name
  the organiser, must not drift between themes. A booking held for the host's
  approval is announced as a request, never as a confirmed meeting; the
  approval check runs before the reschedule check, because a gated reschedule
  re-enters the hold (see `Tymeslot.Bookings.Reschedule`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.ApprovalDisplay
  alias TymeslotWeb.Themes.Shared.Voice

  @type status :: :held | :rescheduled | :confirmed

  @doc "Which of the three outcomes the confirmation step describes."
  @spec status(map()) :: status()
  def status(assigns) do
    cond do
      ApprovalDisplay.awaiting_approval?(assigns) -> :held
      assigns[:is_rescheduling] -> :rescheduled
      true -> :confirmed
    end
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
          dgettext("booking", "%{name}, your request to %{organizer_name} has been sent.",
            name: name,
            organizer_name: organizer_name
          )
        end)

      _no_organizer_name ->
        Voice.line(voice, :held_message, %{name: name}, fn ->
          dgettext("booking", "%{name}, your request has been sent.", name: name)
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
          dgettext("booking", "with %{name}", name: name)
        end)
    end
  end
end
