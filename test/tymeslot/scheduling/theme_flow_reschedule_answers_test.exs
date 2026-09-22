defmodule Tymeslot.Scheduling.ThemeFlowRescheduleAnswersTest do
  @moduledoc """
  Which custom field answers a reschedule carries over from the booking it is
  moving.

  The rule is that an answer follows its question, and only while that question
  still asks the same thing: the booking stores the definitions as the booker
  saw them (`custom_fields_snapshot`), so an edit made since is visible here and
  costs that one answer its carry-over rather than putting old wording's answer
  under new wording.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :custom_fields
  @moduletag :scheduling

  alias Tymeslot.Scheduling.ThemeFlow

  @topic_id "11111111-1111-1111-1111-111111111111"
  @size_id "22222222-2222-2222-2222-222222222222"

  defp topic_question(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => @topic_id,
        "type" => "short_text",
        "label" => "What is it about?",
        "required" => true,
        "position" => 0
      },
      overrides
    )
  end

  defp size_question(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => @size_id,
        "type" => "single_select",
        "label" => "How many of you?",
        "required" => false,
        "position" => 1,
        "options" => [
          %{"key" => "one", "label" => "Just me"},
          %{"key" => "team", "label" => "A team"}
        ]
      },
      overrides
    )
  end

  @policy_id "33333333-3333-3333-3333-333333333333"

  defp policy_note do
    %{
      "id" => @policy_id,
      "type" => "note",
      "label" => "Cancellation policy",
      "body" => "Cancellations within 24 hours are charged in full.",
      "required" => true,
      "position" => 2
    }
  end

  defp booking_with(snapshot, answers) do
    user = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        custom_fields_snapshot: snapshot,
        custom_field_answers: answers
      )

    %{user: user, meeting: meeting}
  end

  test "carries an answer over while its question is unchanged" do
    snapshot = [topic_question(), size_question()]
    answers = %{@topic_id => "Contract renewal", @size_id => "team"}
    %{user: user, meeting: meeting} = booking_with(snapshot, answers)

    assert ThemeFlow.reschedule_answers(meeting.uid, user.id, snapshot) == answers
  end

  test "never carries a note's acknowledgement, even when the note is unchanged" do
    snapshot = [topic_question(), policy_note()]

    answers = %{
      @topic_id => "Contract renewal",
      @policy_id => %{"confirmed" => true, "confirmed_at" => "2026-09-01T10:00:00Z"}
    }

    %{user: user, meeting: meeting} = booking_with(snapshot, answers)

    assert ThemeFlow.reschedule_answers(meeting.uid, user.id, snapshot) ==
             %{@topic_id => "Contract renewal"}
  end

  test "drops the answer to a question whose wording changed" do
    %{user: user, meeting: meeting} =
      booking_with(
        [topic_question(), size_question()],
        %{@topic_id => "Contract renewal", @size_id => "team"}
      )

    edited = [topic_question(%{"label" => "What would you like to discuss?"}), size_question()]

    assert ThemeFlow.reschedule_answers(meeting.uid, user.id, edited) == %{@size_id => "team"}
  end

  test "drops the answer to a question whose options changed" do
    %{user: user, meeting: meeting} =
      booking_with(
        [topic_question(), size_question()],
        %{@topic_id => "Contract renewal", @size_id => "team"}
      )

    edited = [
      topic_question(),
      size_question(%{
        "options" => [
          %{"key" => "one", "label" => "Just me"},
          %{"key" => "team", "label" => "Two or more"}
        ]
      })
    ]

    assert ThemeFlow.reschedule_answers(meeting.uid, user.id, edited) == %{
             @topic_id => "Contract renewal"
           }
  end

  test "carries an answer over when only the question's position changed" do
    %{user: user, meeting: meeting} =
      booking_with(
        [topic_question(), size_question()],
        %{@topic_id => "Contract renewal", @size_id => "team"}
      )

    reordered = [size_question(%{"position" => 0}), topic_question(%{"position" => 1})]

    assert ThemeFlow.reschedule_answers(meeting.uid, user.id, reordered) == %{
             @topic_id => "Contract renewal",
             @size_id => "team"
           }
  end

  test "ignores an answer whose question the host has removed" do
    %{user: user, meeting: meeting} =
      booking_with(
        [topic_question(), size_question()],
        %{@topic_id => "Contract renewal", @size_id => "team"}
      )

    assert ThemeFlow.reschedule_answers(meeting.uid, user.id, [topic_question()]) == %{
             @topic_id => "Contract renewal"
           }
  end

  test "has nothing to carry over for a question added since the booking" do
    %{user: user, meeting: meeting} =
      booking_with([topic_question()], %{@topic_id => "Contract renewal"})

    assert ThemeFlow.reschedule_answers(meeting.uid, user.id, [topic_question(), size_question()]) ==
             %{@topic_id => "Contract renewal"}
  end

  test "carries nothing when there is no reschedule, no organiser or no questions" do
    %{user: user, meeting: meeting} =
      booking_with([topic_question()], %{@topic_id => "Contract renewal"})

    assert ThemeFlow.reschedule_answers(nil, user.id, [topic_question()]) == %{}
    assert ThemeFlow.reschedule_answers(meeting.uid, nil, [topic_question()]) == %{}
    assert ThemeFlow.reschedule_answers(meeting.uid, user.id, []) == %{}
  end

  test "carries nothing for a meeting belonging to another organiser" do
    %{meeting: meeting} = booking_with([topic_question()], %{@topic_id => "Contract renewal"})
    other = insert(:user)

    assert ThemeFlow.reschedule_answers(meeting.uid, other.id, [topic_question()]) == %{}
  end
end
