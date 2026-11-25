defmodule TymeslotWeb.E2E.ReorderTest do
  @moduledoc """
  Drag-to-reorder in the dashboard, through the hooks that implement it:
  `MeetingTypeSortable` on the meeting types list and `QuestionsSortable` on a
  meeting type's custom questions.

  Both hooks listen for native HTML5 drag events, which WebDriver cannot
  produce (its pointer actions never start a native drag). The tests therefore
  dispatch the `dragstart`, `dragover`, `drop` and `dragend` sequence a real
  drag fires, with a shared `DataTransfer`, on the items themselves. The hook
  then does everything a drag does: it moves the item to where the pointer is
  and pushes the order it reads from the DOM. Nothing here pushes the
  LiveView event directly.
  """
  use TymeslotWeb.BrowserCase, async: false

  @moduletag :e2e
  @moduletag :meeting_types
  @moduletag :custom_fields

  import Tymeslot.TestHelpers.Eventually

  alias Ecto.UUID
  alias Tymeslot.MeetingTypes

  @types_list "#meeting-types-sortable-list"
  # One meeting type form is open at a time; its list's id carries the form id.
  @questions_list "ul[id^='custom-questions-list-']"

  # Fires the native drag sequence that moves the item at `from` to the slot
  # of the item at `to` (pointer over the upper edge of the target, so the
  # hook inserts before it). Returns whether the hook moved the item.
  #
  # The hooks load lazily, so the first attempt can land before one is
  # listening. A drag nobody handles moves nothing, and the script then drops
  # nothing either, so the caller retries until the hook is in place.
  @drag_js """
  const [listSelector, from, to] = arguments;
  const list = document.querySelector(listSelector);
  if (!list) return false;

  const items = () => Array.from(list.querySelectorAll(':scope > [draggable="true"]'));
  const source = items()[from];
  const target = items()[to];
  const dataTransfer = new DataTransfer();
  const fire = (el, type, clientY) =>
    el.dispatchEvent(new DragEvent(type, {
      bubbles: true, cancelable: true, dataTransfer, clientX: 1, clientY
    }));

  const y = target.getBoundingClientRect().top + 1;
  fire(source, 'dragstart', y);
  fire(target, 'dragover', y);

  const moved = items().indexOf(source) === to;
  if (moved) fire(list, 'drop', y);
  fire(source, 'dragend', y);

  return moved;
  """

  feature "dragging a meeting type to the top reorders the list and keeps the order", %{
    session: session
  } do
    {session, user} = log_in_via_browser(session)

    for {name, order} <- [{"Alpha Call", 100}, {"Bravo Call", 101}, {"Charlie Call", 102}] do
      insert(:meeting_type, user: user, name: name, sort_order: order)
    end

    before = db_type_names(user.id)
    assert Enum.take(before, -3) == ["Alpha Call", "Bravo Call", "Charlie Call"]
    last = length(before) - 1
    expected = ["Charlie Call" | List.delete(before, "Charlie Call")]

    session =
      session
      |> visit("/dashboard/meeting-settings")
      |> wait_for_live()
      |> assert_has(css("#{@types_list} [data-meeting-type-id]", count: length(before)))

    assert screen_type_names(session) == before

    drag(session, @types_list, last, 0)

    session
    |> assert_has(css("#app-flash-group-info", text: "Meeting types reordered"))
    |> assert_has(css("#{@types_list}:not(.pointer-events-none)"))

    eventually(fn -> db_type_names(user.id) == expected end, timeout: 5_000)
    assert screen_type_names(session) == expected

    session
    |> visit("/dashboard/meeting-settings")
    |> wait_for_live()
    |> assert_has(css("#{@types_list} [data-meeting-type-id]", count: length(before)))

    assert screen_type_names(session) == expected
  end

  feature "dragging a booking question to the top saves the new order", %{session: session} do
    {session, user} = log_in_via_browser(session)
    meeting_type = insert(:meeting_type, user: user, name: "Questions Call")

    questions =
      for {label, i} <- Enum.with_index(["Company", "Role", "Agenda"]) do
        %{"id" => UUID.generate(), "type" => "short_text", "label" => label, "position" => i}
      end

    {:ok, _meeting_type} =
      MeetingTypes.update_meeting_type(meeting_type, %{"custom_fields" => questions})

    labels = Map.new(questions, &{&1["id"], &1["label"]})

    session = open_questions(session, meeting_type)
    assert screen_question_labels(session, labels) == ["Company", "Role", "Agenda"]

    drag(session, @questions_list, 2, 0)

    session = assert_has(session, css("[aria-live='polite']", text: "All changes saved"))

    expected = ["Agenda", "Company", "Role"]

    eventually(fn -> db_question_labels(meeting_type, user) == expected end, timeout: 5_000)
    assert screen_question_labels(session, labels) == expected

    session = open_questions(session, meeting_type)
    assert screen_question_labels(session, labels) == expected
  end

  defp drag(session, list, from, to) do
    eventually(
      fn ->
        me = self()
        ref = make_ref()
        execute_script(session, @drag_js, [list, from, to], &send(me, {ref, &1}))
        assert_receive {^ref, moved}, 5_000
        moved
      end,
      timeout: 5_000,
      interval: 200,
      message: "the sortable hook on #{list} never moved the dragged item"
    )
  end

  defp open_questions(session, meeting_type) do
    session
    |> visit("/dashboard/meeting-settings")
    |> wait_for_live()
    |> click(css("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']"))
    |> click(css("[role='tab']", text: "Questions"))
    |> assert_has(css("#{@questions_list} > li[data-id]", count: 3))
  end

  defp screen_type_names(session) do
    evaluate_script(session, """
    return Array.from(document.querySelectorAll("#{@types_list} > [data-meeting-type-id] h2"))
      .map(h => h.textContent.trim());
    """)
  end

  # The labels in the order the rows stand on screen. Rows are matched to
  # questions by their `data-id`, and each row must show its own label.
  defp screen_question_labels(session, labels) do
    session
    |> evaluate_script("""
    return Array.from(document.querySelectorAll("#{@questions_list} > li[data-id]"))
      .map(li => [li.dataset.id, li.textContent]);
    """)
    |> Enum.map(fn [id, text] ->
      label = Map.fetch!(labels, id)
      assert text =~ label
      label
    end)
  end

  defp db_type_names(user_id) do
    user_id
    |> MeetingTypes.get_active_meeting_types()
    |> Enum.map(& &1.name)
  end

  defp db_question_labels(meeting_type, user) do
    meeting_type.id
    |> MeetingTypes.get_meeting_type(user.id)
    |> Map.fetch!(:custom_fields)
    |> Enum.sort_by(& &1.position)
    |> Enum.map(& &1.label)
  end
end
