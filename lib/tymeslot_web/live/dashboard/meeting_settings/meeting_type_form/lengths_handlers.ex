defmodule TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.LengthsHandlers do
  @moduledoc """
  Event handling for the meeting-type form's further lengths
  (`MeetingTypeForm.LengthsField`): adding a row with a suggested length and
  removing one. Each change revalidates the list against the primary
  duration and autosaves, as an edit to any other field of the form does.
  """

  alias Phoenix.Component
  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.MeetingSettings.Helpers
  alias TymeslotWeb.Dashboard.MeetingSettings.MeetingTypeForm.{Autosave, LengthsField, Validation}

  @doc "The form's events for the further lengths; `MeetingTypeForm` hands each of them here."
  @spec events() :: [String.t()]
  def events, do: ~w(add_length remove_length)

  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          Phoenix.LiveView.Socket.t()
  def handle_event("add_length", _params, socket) do
    form_data = socket.assigns.form_data || %{}
    extras = Map.get(form_data, "extra_lengths", [])

    # A group type offers one length; the button is hidden, this stops a
    # stale or forged event.
    if not socket.assigns.group_bookings_enabled and
         length(extras) + 1 < Constraints.max_lengths_per_meeting_type() do
      update_extra_lengths(socket, extras ++ [LengthsField.suggest(form_data)])
    else
      socket
    end
  end

  def handle_event("remove_length", %{"index" => index}, socket) do
    extras = Map.get(socket.assigns.form_data || %{}, "extra_lengths", [])

    case Integer.parse(to_string(index)) do
      {position, ""} when position >= 0 and position < length(extras) ->
        update_extra_lengths(socket, List.delete_at(extras, position))

      _other ->
        socket
    end
  end

  def handle_event(_event, _params, socket), do: socket

  defp update_extra_lengths(socket, extras) do
    {data, errors} =
      Validation.revalidate_extra_lengths(
        Map.put(socket.assigns.form_data || %{}, "extra_lengths", extras),
        socket.assigns.form_errors || %{},
        Helpers.get_security_metadata(socket)
      )

    socket
    |> Component.assign(form_data: data, form_errors: errors)
    |> Autosave.maybe_run()
  end
end
