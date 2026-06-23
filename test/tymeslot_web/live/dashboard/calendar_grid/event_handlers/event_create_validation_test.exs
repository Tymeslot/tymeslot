defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventCreateValidationTest do
  @moduledoc """
  Covers the validation arms inside `handle_save_event/2`:

    * Submitting with an integration_id that no longer matches → "Invalid calendar selected".
    * Submitting an unparseable date string → "Invalid date".
    * Submitting an end time at or before the start time → "End time must be after start time".

  Each path short-circuits before reaching the worker, so we assert by
  receiving the `{:flash, {:error, _}}` message the handler sends to itself.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateExecution

  defp build_socket(opts \\ []) do
    user = insert(:user)

    integration =
      Keyword.get_lazy(opts, :integration, fn ->
        insert(:calendar_integration, user: user, is_active: true)
      end)

    creating =
      Map.merge(
        %{
          title: "Standup",
          integration_id: integration.id,
          calendar_id: "primary",
          all_day: false,
          date: "2026-04-10",
          end_date: "2026-04-10",
          start_hour: 10,
          start_minute: 0,
          end_hour: 11,
          end_minute: 0,
          attendees: [],
          video_integration_id: nil,
          description: nil
        },
        Keyword.get(opts, :creating_overrides, %{})
      )

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        creating_event: creating,
        integrations: [integration],
        user_timezone: "Europe/Tallinn"
      }
    }
  end

  describe "handle_save_event/2 — invalid calendar" do
    test "flashes when the selected integration is missing from assigns" do
      socket =
        build_socket(creating_overrides: %{integration_id: 999_999})

      {:noreply, _socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_received {:flash, {:error, "Invalid calendar selected"}}
    end
  end

  describe "handle_save_event/2 — invalid date" do
    test "flashes when start date cannot be parsed" do
      socket = build_socket(creating_overrides: %{date: "not-a-date"})

      {:noreply, _socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_received {:flash, {:error, "Invalid date"}}
    end

    test "flashes when end date cannot be parsed" do
      socket = build_socket(creating_overrides: %{end_date: "13-04-2026"})

      {:noreply, _socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_received {:flash, {:error, "Invalid date"}}
    end
  end

  describe "handle_save_event/2 — end time at or before start time" do
    test "rejects when end is before start on the same day" do
      socket =
        build_socket(
          creating_overrides: %{
            start_hour: 11,
            start_minute: 0,
            end_hour: 10,
            end_minute: 0
          }
        )

      {:noreply, _socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_received {:flash, {:error, "End time must be after start time"}}
    end

    test "rejects a zero-length slot" do
      socket =
        build_socket(
          creating_overrides: %{
            start_hour: 10,
            start_minute: 0,
            end_hour: 10,
            end_minute: 0
          }
        )

      {:noreply, _socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_received {:flash, {:error, "End time must be after start time"}}
    end
  end

  describe "handle_save_event/2 — happy gate" do
    test "schedules the create-event execute message when validation passes" do
      socket = build_socket()

      {:noreply, updated_socket} = CreateExecution.handle_save_event(%{}, socket)

      assert updated_socket.assigns.saving_event == true
      assert_received {:execute_create_event, payload}
      assert payload.creating.title == "Standup"
      assert DateTime.compare(payload.start_at, ~U[2026-04-10 07:00:00Z]) == :eq
      assert DateTime.compare(payload.end_at, ~U[2026-04-10 08:00:00Z]) == :eq
    end
  end

  describe "handle_save_event/2 — all-day events" do
    test "schedules an all-day create with Date start/end and all_day: true" do
      socket =
        build_socket(
          creating_overrides: %{
            all_day: true,
            date: "2026-04-18",
            # Inclusive last day picked by the user; stored exclusively as +1.
            end_date: "2026-04-18"
          }
        )

      {:noreply, updated_socket} = CreateExecution.handle_save_event(%{}, socket)

      assert updated_socket.assigns.saving_event == true
      assert_received {:execute_create_event, payload}
      assert payload.all_day == true
      assert payload.start_at == ~D[2026-04-18]
      # end_date is exclusive: a single-day all-day event ends on the next day.
      assert payload.end_at == ~D[2026-04-19]
    end

    test "rejects an all-day event whose end date precedes its start date" do
      socket =
        build_socket(
          creating_overrides: %{
            all_day: true,
            date: "2026-04-19",
            end_date: "2026-04-18"
          }
        )

      {:noreply, _socket} = CreateExecution.handle_save_event(%{}, socket)

      assert_received {:flash, {:error, "End date must not be before start date"}}
    end
  end

  describe "handle_save_event/2 — no creating_event in assigns" do
    test "is a no-op when there is no in-progress event" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, creating_event: nil}
      }

      {:noreply, returned_socket} = CreateExecution.handle_save_event(%{}, socket)
      assert returned_socket == socket

      refute_received {:flash, _}
      refute_received {:execute_create_event, _}
    end
  end
end
