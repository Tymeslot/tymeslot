defmodule TymeslotWeb.Themes.Shared.Journey.Facts.SeriesTest do
  use ExUnit.Case, async: true

  @moduletag :scheduling
  @moduletag :themes

  alias Phoenix.LiveView.Socket
  alias Tymeslot.BookingSeries.Occurrence
  alias Tymeslot.MeetingTypes.MeetingTypeSchema
  alias TymeslotWeb.Themes.Quill.Scheduling.Live, as: QuillLive
  alias TymeslotWeb.Themes.Shared.Journey
  alias TymeslotWeb.Themes.Shared.Journey.Facts.Series
  alias TymeslotWeb.Themes.Shared.Journey.Navigators.Paged
  alias TymeslotWeb.Themes.Shared.Journey.Runtime

  @type_attrs %MeetingTypeSchema{
    id: 7,
    duration_minutes: 30,
    series_mode: :recurring,
    series_frequency: :weekly,
    series_interval: 1,
    series_min_occurrences: 2,
    series_max_occurrences: 6,
    series_required: true
  }

  @first ~U[2026-12-01 10:00:00Z]

  defp socket(assigns), do: %Socket{assigns: Map.merge(%{__changed__: %{}, flash: %{}}, assigns)}

  # A booking on Quill's journey, which asks the series, for a type whose
  # series is offered, with the slot picked at `@first`.
  defp booking(assigns \\ %{}) do
    Map.merge(
      %{
        journey: QuillLive.__journey__(),
        meeting_type: @type_attrs,
        series_offered?: true,
        series_single_allowed?: false,
        selected_date: "2026-12-01",
        selected_time: "10:00",
        user_timezone: "Etc/UTC",
        reschedule_meeting_uid: nil,
        reschedule_seat_token: nil
      },
      assigns
    )
  end

  defp choice(count \\ 3), do: %{mode: :recurring, starts: [@first], count: count}

  defp occurrence(position, status \\ :available) do
    start = DateTime.add(@first, (position - 1) * 7, :day)

    %Occurrence{
      position: position,
      start: start,
      end: DateTime.add(start, 30, :minute),
      status: status
    }
  end

  defp checked(choice, occurrences) do
    booking(%{
      series_choice: choice,
      series_preview: occurrences,
      series_preview_key: Series.key(choice),
      series_checking?: false
    })
  end

  test "is the series, needed once the slot is known, from the series events" do
    assert Series.key() == :series
    assert Series.requires(%{}) == [:slot]
    assert :series_set_count in Series.events()
    assert Journey.facts()[:series] == Series
  end

  describe "required?/1" do
    test "for a type whose series is offered, on a journey that asks it" do
      assert Series.required?(booking())
    end

    test "not when the series is not offered" do
      refute Series.required?(booking(%{series_offered?: false}))
    end

    test "not on a reschedule, which moves one session" do
      refute Series.required?(booking(%{reschedule_meeting_uid: "uid"}))
      refute Series.required?(booking(%{reschedule_seat_token: "token"}))
    end

    test "not on a journey without a moment asking it" do
      journey =
        Journey.new(
          navigator: Paged,
          moments: [
            {:overview, collects: [:meeting_type], component: nil},
            {:schedule, collects: [:slot], component: nil}
          ],
          outcomes: %{}
        )

      refute Series.required?(booking(%{journey: journey}))
    end
  end

  describe "known?/1" do
    test "once the last check found every session available" do
      assert Series.known?(checked(choice(), Enum.map(1..3, &occurrence/1)))
    end

    test "not while one session is unavailable, which continue/1 names" do
      lost = occurrence(2, {:unavailable, :booked})
      assigns = checked(choice(), [occurrence(1), lost, occurrence(3)])

      refute Series.known?(assigns)
      assert Series.continue(socket(assigns)) == {:error, {:occurrences_unavailable, [lost]}}
    end

    test "not while a check is in flight, nor for a check of another choice" do
      occurrences = Enum.map(1..3, &occurrence/1)

      refute Series.known?(%{checked(choice(), occurrences) | series_checking?: true})

      stale = %{checked(choice(), occurrences) | series_choice: choice(4)}
      refute Series.known?(stale)
      assert Series.continue(socket(stale)) == {:error, :series_required}
    end

    test "not for a checked choice made for another time than the one picked" do
      checked = checked(choice(), Enum.map(1..3, &occurrence/1))

      refute Series.known?(%{checked | selected_time: "11:00"})
      refute Series.known?(%{checked | selected_time: nil})
    end

    test "while a known choice the booker changed is checked again" do
      known = socket(checked(choice(), Enum.map(1..3, &occurrence/1)))
      {:noreply, recounted} = Series.handle(known, :series_set_count, "4")

      assert Series.rechecking?(recounted.assigns)
      assert Series.known?(recounted.assigns)
      assert Series.keeps_dependents?(known.assigns, recounted.assigns)
    end

    test "not while a choice that was not known is checked again" do
      lost = occurrence(2, {:unavailable, :booked})
      unknown = socket(checked(choice(), [occurrence(1), lost, occurrence(3)]))
      {:noreply, recounted} = Series.handle(unknown, :series_set_count, "4")

      refute Series.rechecking?(recounted.assigns)
      refute Series.known?(recounted.assigns)
      refute Series.keeps_dependents?(unknown.assigns, recounted.assigns)
    end

    test "a single session only where the type allows one" do
      assert Series.known?(booking(%{series_choice: :single, series_single_allowed?: true}))
      refute Series.known?(booking(%{series_choice: :single, series_single_allowed?: false}))
    end

    test "not before anything is chosen" do
      refute Series.known?(booking(%{series_choice: nil}))
    end
  end

  describe "handle/3" do
    test "series_single is refused where the series is required" do
      socket = socket(booking(%{series_choice: choice(), series_checking?: false}))

      assert {:noreply, ^socket} = Series.handle(socket, :series_single, nil)
    end

    test "series_single chooses one session where the type allows it" do
      socket =
        socket(
          booking(%{
            series_choice: choice(),
            series_checking?: false,
            series_single_allowed?: true
          })
        )

      assert {:noreply, single} = Series.handle(socket, :series_single, nil)
      assert single.assigns.series_choice == :single
    end

    test "a count outside the type's range, or not a number, is ignored" do
      socket = socket(booking(%{series_choice: choice(), series_checking?: false}))

      for value <- ["1", "7", "lots", %{"count" => 3}] do
        assert {:noreply, ^socket} = Series.handle(socket, :series_set_count, value)
      end
    end

    test "a session the picker does not offer is not added" do
      flexible = %{@type_attrs | series_mode: :flexible}

      socket =
        socket(
          booking(%{
            meeting_type: flexible,
            series_choice: %{mode: :flexible, starts: [@first], count: 1},
            series_checking?: false,
            series_picker: %{
              week_start: ~D[2026-11-30],
              days: %{},
              loading?: false,
              error: nil,
              day: nil
            }
          })
        )

      start = DateTime.to_iso8601(DateTime.add(@first, 1, :day))
      assert {:noreply, ^socket} = Series.handle(socket, :series_add_start, start)
      assert {:noreply, ^socket} = Series.handle(socket, :series_add_start, "not a time")
    end
  end

  describe "changing the slot" do
    test "clear/1 forgets the choice and its check" do
      cleared = Series.clear(socket(checked(choice(), Enum.map(1..3, &occurrence/1))))

      assert cleared.assigns.series_choice == nil
      assert cleared.assigns.series_preview == nil
      refute Series.known?(cleared.assigns)
    end

    test "forgetting the slot forgets the series too" do
      socket = socket(checked(choice(), Enum.map(1..3, &occurrence/1)))

      assert Runtime.clear(socket, [:slot]).assigns.series_choice == nil
    end

    test "entering the moment after another time was picked starts again from it" do
      socket = socket(checked(choice(5), Enum.map(1..5, &occurrence/1)))
      moved = %{socket | assigns: %{socket.assigns | selected_time: "11:00"}}

      entered = Series.enter(moved, %{})

      assert entered.assigns.series_choice == %{
               mode: :recurring,
               starts: [~U[2026-12-01 11:00:00Z]],
               count: 2
             }

      refute Series.known?(entered.assigns)
    end

    test "refresh/1 remakes a choice for another time, and one forgotten with its slot" do
      socket = socket(checked(choice(5), Enum.map(1..5, &occurrence/1)))
      moved = %{socket | assigns: %{socket.assigns | selected_time: "11:00"}}
      remade = %{mode: :recurring, starts: [~U[2026-12-01 11:00:00Z]], count: 2}

      assert Series.refresh(moved).assigns.series_choice == remade

      forgotten = %{moved | assigns: %{moved.assigns | series_choice: nil}}
      assert Series.refresh(forgotten).assigns.series_choice == remade

      assert Series.refresh(socket).assigns.series_choice == choice(5)
    end

    test "entering the moment again for the same time keeps the choice" do
      socket = socket(checked(choice(5), Enum.map(1..5, &occurrence/1)))

      assert Series.enter(socket, %{}).assigns.series_choice == choice(5)
    end
  end

  test "request/1 is the series a submission asks for, nil for a single session" do
    assert Series.request(checked(choice(4), [])) == %{
             mode: :recurring,
             first_start: @first,
             count: 4
           }

    assert Series.request(booking(%{series_choice: :single, series_single_allowed?: true})) == nil
    assert Series.request(Map.put(checked(choice(4), []), :series_offered?, false)) == nil
  end

  describe "handle_async/3" do
    test "a check of a choice no longer on screen is dropped" do
      socket = socket(booking(%{series_choice: choice(3), series_checking?: true}))
      stale = {Series.key(choice(4)), {:ok, Enum.map(1..4, &occurrence/1)}}

      assert {:noreply, ^socket} = Series.handle_async(:series_preview, {:ok, stale}, socket)
    end

    test "a check of the choice on screen is applied" do
      socket = socket(booking(%{series_choice: choice(3), series_checking?: true}))
      result = {Series.key(choice(3)), {:ok, Enum.map(1..3, &occurrence/1)}}

      assert {:noreply, checked} = Series.handle_async(:series_preview, {:ok, result}, socket)
      assert Series.known?(checked.assigns)
      refute checked.assigns.series_checking?
    end

    test "a check that could not read the calendar says so and is not known" do
      socket = socket(booking(%{series_choice: choice(3), series_checking?: true}))
      result = {Series.key(choice(3)), {:error, :availability_unverifiable}}

      assert {:noreply, failed} = Series.handle_async(:series_preview, {:ok, result}, socket)
      assert failed.assigns.series_error == :availability_unverifiable
      refute Series.known?(failed.assigns)
    end

    test "a failed check no longer waited for changes nothing" do
      socket =
        socket(%{checked(choice(), Enum.map(1..3, &occurrence/1)) | series_checking?: false})

      assert {:noreply, ^socket} = Series.handle_async(:series_preview, {:exit, :boom}, socket)
    end

    test "a crashed check is unverifiable; a cancelled one changes nothing" do
      socket = socket(booking(%{series_choice: choice(3), series_checking?: true}))

      assert {:noreply, ^socket} =
               Series.handle_async(:series_preview, {:exit, {:shutdown, :cancel}}, socket)

      assert {:noreply, crashed} = Series.handle_async(:series_preview, {:exit, :boom}, socket)
      assert crashed.assigns.series_error == :availability_unverifiable
      refute crashed.assigns.series_checking?
    end
  end

  describe "a flexible series" do
    defp flexible_booking(starts) do
      booking(%{
        meeting_type: %{@type_attrs | series_mode: :flexible},
        series_choice: %{mode: :flexible, starts: starts, count: length(starts)},
        series_checking?: false
      })
    end

    test "removing a session keeps the rest, and the first session stays" do
      second = DateTime.add(@first, 1, :day)
      third = DateTime.add(@first, 2, :day)
      socket = socket(flexible_booking([@first, second, third]))

      assert {:noreply, removed} =
               Series.handle(socket, :series_remove_start, DateTime.to_iso8601(second))

      assert removed.assigns.series_choice.starts == [@first, third]

      assert {:noreply, ^removed} =
               Series.handle(removed, :series_remove_start, DateTime.to_iso8601(@first))
    end
  end

  describe "merge_lost/2" do
    test "names the lost sessions beside the rest, even before any check answered" do
      socket = socket(booking(%{series_choice: choice(3), series_preview: nil}))
      lost = occurrence(2, {:unavailable, :booked})

      merged = Series.merge_lost(socket, [lost])

      assert Enum.map(Series.rows(merged.assigns), & &1.status) ==
               [:pending, {:unavailable, :booked}]

      assert Series.unavailable(merged.assigns) == [lost]
    end

    test "lays the lost sessions over a check that answered" do
      socket = socket(checked(choice(3), Enum.map(1..3, &occurrence/1)))
      lost = occurrence(3, {:unavailable, :booked})

      merged = Series.merge_lost(socket, [lost])

      assert Enum.map(Series.rows(merged.assigns), & &1.status) ==
               [:available, :available, {:unavailable, :booked}]
    end
  end

  test "clear/1 forgets the series a booking made" do
    socket = socket(Map.merge(booking(), %{series: %{uid: "s"}, series_meetings: [%{id: 1}]}))
    cleared = Series.clear(socket)

    assert cleared.assigns.series == nil
    assert cleared.assigns.series_meetings == []
  end
end
