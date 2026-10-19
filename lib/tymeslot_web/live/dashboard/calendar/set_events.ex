defmodule TymeslotWeb.Dashboard.Calendar.SetEvents do
  @moduledoc """
  The calendar sets' events, routed here by `PowerEvents`: applying a set
  (its digit, its rail row; 0 leaves it), the inline name field for a new
  set or a rename, saving it, and deleting a set. Positions arrive from the
  browser as integers or digit strings and are parsed again; a position
  with no set of the organiser's changes nothing.

  A new set keeps what shows now (`CalendarSets.members_from/2` over the
  effective visibility) and becomes the active set. Applying, leaving and
  deleting the active set re-resolve what is hidden and push the window
  (`Visibility.refresh/1`), whose payload carries the new `sets` and
  `active_set` settings; a rename only pushes the settings.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Tymeslot.CalendarGrid.CalendarSets
  alias Tymeslot.CalendarGrid.EffectiveVisibility
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Visibility
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  @spec handle(String.t(), map(), socket()) :: {:noreply, socket()}
  def handle("calendar:apply_set", %{"position" => raw}, socket) do
    case parse_position(raw, 0..9) do
      {:ok, position} -> {:noreply, apply_set(socket, position)}
      :error -> {:noreply, socket}
    end
  end

  def handle("calendar:edit_set", %{"new" => "true"}, socket),
    do: {:noreply, assign(socket, :set_editor, :new)}

  def handle("calendar:edit_set", %{"position" => raw}, socket) do
    with {:ok, position} <- parse_position(raw, 1..9),
         true <- Enum.any?(socket.assigns.calendar_sets, &(&1.position == position)) do
      {:noreply, assign(socket, :set_editor, {:rename, position})}
    else
      _no_such_set -> {:noreply, socket}
    end
  end

  def handle("calendar:cancel_set_edit", _params, socket) do
    target =
      case socket.assigns.set_editor do
        {:rename, position} -> "set-#{position}"
        _new_or_none -> "new-set"
      end

    {:noreply, socket |> assign(:set_editor, nil) |> focus(target)}
  end

  def handle("calendar:save_set", %{"name" => name}, socket) when is_binary(name),
    do: {:noreply, limited(socket, &save(&1, &1.assigns.set_editor, name))}

  def handle("calendar:delete_set", %{"position" => raw}, socket) do
    case parse_position(raw, 1..9) do
      {:ok, position} -> {:noreply, limited(socket, &delete(&1, position))}
      :error -> {:noreply, socket}
    end
  end

  def handle(_event, _params, socket), do: {:noreply, socket}

  defp apply_set(socket, position) do
    user_id = socket.assigns.current_user.id

    with false <- active_position(socket) == position,
         :ok <- RateLimiter.check(:calendar_visibility, user_id),
         {:ok, set} <- CalendarSets.activate(user_id, position) do
      socket |> assign(:set_editor, nil) |> activated(set)
    else
      true -> socket
      {:error, :rate_limited, message} -> Flash.put_flash(socket, :warning, message)
      {:error, :not_found} -> socket
      {:error, _changeset} -> failed(socket)
    end
  end

  # Saving and deleting share the visibility budget with applying a set.
  defp limited(socket, fun) do
    case RateLimiter.check(:calendar_visibility, socket.assigns.current_user.id) do
      :ok -> fun.(socket)
      {:error, :rate_limited, message} -> Flash.put_flash(socket, :warning, message)
    end
  end

  defp save(socket, :new, name) do
    %{current_user: %{id: user_id}, integrations: integrations} = socket.assigns
    members = CalendarSets.members_from(integrations, shown(socket.assigns))

    with {:ok, created} <- CalendarSets.create(user_id, name, members),
         {:created, {:ok, set}} <- {:created, CalendarSets.activate(user_id, created.position)} do
      socket
      |> assign(set_editor: nil, calendar_sets: CalendarSets.list(user_id))
      |> activated(set)
      |> focus("set-#{set.position}")
    else
      # The set exists but could not be switched on: show it, and say so.
      {:created, _failure} ->
        socket |> assign(:calendar_sets, CalendarSets.list(user_id)) |> save_failed()

      {:error, :limit} ->
        Flash.put_flash(
          socket,
          :error,
          dgettext("dashboard_calendar_power", "You can keep up to nine calendar sets.")
        )

      {:error, %Ecto.Changeset{errors: errors}} ->
        # Two tabs saving at once can take the same position: not the name's fault.
        if Keyword.has_key?(errors, :position),
          do: save_failed(socket),
          else: name_refused(socket)
    end
  end

  defp save(socket, {:rename, position}, name) do
    case CalendarSets.rename(socket.assigns.current_user.id, position, name) do
      {:ok, set} ->
        socket
        |> assign(:set_editor, nil)
        |> Visibility.put_set(set)
        |> SurfaceData.push_settings()
        |> focus("set-#{position}")

      {:error, :not_found} ->
        assign(socket, :set_editor, nil)

      {:error, _changeset} ->
        name_refused(socket)
    end
  end

  defp save(socket, nil, _name), do: socket

  defp delete(socket, position) do
    case CalendarSets.delete(socket.assigns.current_user.id, position) do
      {:ok, _set} ->
        sets = Enum.reject(socket.assigns.calendar_sets, &(&1.position == position))
        socket = assign(socket, calendar_sets: sets, set_editor: nil)

        # The foreign key has already cleared the stored active set.
        socket =
          if active_position(socket) == position,
            do: activated(socket, nil),
            else: SurfaceData.push_settings(socket)

        focus(socket, "new-set")

      {:error, _not_found} ->
        assign(socket, :set_editor, nil)
    end
  end

  defp activated(socket, set) do
    socket
    |> SurfaceData.put_preference(:active_calendar_set_id, set && set.id)
    |> assign(:active_set, set)
    |> Visibility.refresh()
  end

  defp shown(assigns),
    do: %EffectiveVisibility{
      hidden_integration_ids: assigns.hidden_integration_ids,
      hidden_calendar_keys: assigns.hidden_calendar_keys,
      active_set: assigns.active_set
    }

  defp active_position(%{assigns: %{active_set: %{position: position}}}), do: position
  defp active_position(_socket), do: 0

  defp parse_position(raw, range) when is_integer(raw),
    do: if(raw in range, do: {:ok, raw}, else: :error)

  defp parse_position(raw, range) when is_binary(raw) do
    case Integer.parse(raw) do
      {position, ""} -> parse_position(position, range)
      _other -> :error
    end
  end

  defp parse_position(_raw, _range), do: :error

  defp save_failed(socket) do
    Flash.put_flash(
      socket,
      :error,
      dgettext("dashboard_calendar_power", "Couldn't save the set. Please try again.")
    )
  end

  # Gives focus back to a control once the editor that held it closes: the
  # rail's or the sheet's, whichever is on screen (the hook picks).
  defp focus(socket, id),
    do:
      push_event(socket, "calendar:focus", %{ids: ["calendar-rail-#{id}", "calendar-sheet-#{id}"]})

  defp name_refused(socket) do
    Flash.put_flash(
      socket,
      :error,
      dgettext(
        "dashboard_calendar_power",
        "Couldn't save the set. Give it a name of up to 40 characters."
      )
    )
  end

  defp failed(socket) do
    Flash.put_flash(
      socket,
      :error,
      dgettext("dashboard_calendar", "Couldn't save that change. Please try again.")
    )
  end
end
