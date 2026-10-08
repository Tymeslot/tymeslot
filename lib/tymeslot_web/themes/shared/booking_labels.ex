defmodule TymeslotWeb.Themes.Shared.BookingLabels do
  @moduledoc """
  Labels shared by every theme's booking form.

  Both themes ask the same two questions of the same data (what does the submit
  button say, and what do we call the organiser), and answered them with
  byte-identical private copies that differed only in the label used when the
  meeting type is ungated. Approval added a third and fourth branch to that
  `cond`, which is exactly the point at which two copies start to drift: a
  wording fix applied to one theme silently leaves the other behind.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Profiles
  alias Tymeslot.Themes.Catalog
  alias TymeslotWeb.Themes.Shared.Voice

  @doc """
  The submit button's label, in the voice of the theme with key `theme_key`
  where it has one.

  A gated meeting type submits a request rather than a booking, and says so, so
  that nobody presses a button reading "Book meeting" and receives a held
  request instead. `ungated_label` is the theme's own wording for the ordinary
  case ("Book meeting", "Submit"), passed in already translated so each theme
  keeps its own literal at its own call site for extraction; a voice wording
  `:submit` replaces it.
  """
  @spec submit_label(boolean(), term(), String.t(), Catalog.theme_key() | nil) :: String.t()
  def submit_label(is_rescheduling, meeting_type, ungated_label, theme_key \\ nil) do
    voice = Voice.of(theme_key)

    cond do
      Approval.required?(meeting_type) and is_rescheduling ->
        Voice.line(voice, :submit_request_reschedule, %{}, fn ->
          dgettext("booking", "Request new time")
        end)

      Approval.required?(meeting_type) ->
        Voice.line(voice, :submit_request, %{}, fn -> dgettext("booking", "Request meeting") end)

      is_rescheduling ->
        Voice.line(voice, :submit_reschedule, %{}, fn ->
          dgettext("booking", "Reschedule Meeting")
        end)

      true ->
        Voice.line(voice, :submit, %{}, fn -> ungated_label end)
    end
  end

  @doc """
  The organiser's display name, falling back to the username the page was
  reached by when the profile carries no name.
  """
  @spec organizer_display_name(term(), String.t() | nil) :: String.t() | nil
  def organizer_display_name(organizer_profile, username_context) do
    Profiles.display_name(organizer_profile) || username_context
  end
end
