defmodule Tymeslot.Integrations.Calendar.ReminderTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.Reminder

  describe "normalise/1" do
    test "normalises an atom-keyed popup reminder" do
      reminder = %{method: :popup, minutes_before: 10}
      assert Reminder.normalise(reminder) == %{method: :popup, minutes_before: 10}
    end

    test "normalises an atom-keyed email reminder" do
      reminder = %{method: :email, minutes_before: 60}
      assert Reminder.normalise(reminder) == %{method: :email, minutes_before: 60}
    end

    test "normalises an atom-keyed sms reminder" do
      reminder = %{method: :sms, minutes_before: 15}
      assert Reminder.normalise(reminder) == %{method: :sms, minutes_before: 15}
    end

    test "normalises a string-keyed popup reminder (JSONB round-trip)" do
      reminder = %{"method" => "popup", "minutes_before" => 10}
      assert Reminder.normalise(reminder) == %{method: :popup, minutes_before: 10}
    end

    test "normalises a string-keyed email reminder (JSONB round-trip)" do
      reminder = %{"method" => "email", "minutes_before" => 30}
      assert Reminder.normalise(reminder) == %{method: :email, minutes_before: 30}
    end

    test "normalises a string-keyed sms reminder (JSONB round-trip)" do
      reminder = %{"method" => "sms", "minutes_before" => 5}
      assert Reminder.normalise(reminder) == %{method: :sms, minutes_before: 5}
    end

    test "defaults to :popup for an unrecognised method" do
      reminder = %{method: :unknown, minutes_before: 20}
      assert Reminder.normalise(reminder).method == :popup
    end

    test "defaults to :popup when method is nil" do
      reminder = %{minutes_before: 10}
      assert Reminder.normalise(reminder).method == :popup
    end
  end

  describe "method/1" do
    test "returns :popup for :popup atom key" do
      assert Reminder.method(%{method: :popup}) == :popup
    end

    test "returns :email for :email atom key" do
      assert Reminder.method(%{method: :email}) == :email
    end

    test "returns :sms for :sms atom key" do
      assert Reminder.method(%{method: :sms}) == :sms
    end

    test "returns :popup for string key popup" do
      assert Reminder.method(%{"method" => "popup"}) == :popup
    end

    test "returns :email for string key email" do
      assert Reminder.method(%{"method" => "email"}) == :email
    end

    test "returns :sms for string key sms" do
      assert Reminder.method(%{"method" => "sms"}) == :sms
    end

    test "returns :popup when method key is absent" do
      assert Reminder.method(%{minutes_before: 10}) == :popup
    end
  end

  describe "google_method/1" do
    test "maps :popup to popup" do
      assert Reminder.google_method(:popup) == "popup"
    end

    test "maps :email to email" do
      assert Reminder.google_method(:email) == "email"
    end

    test "maps string email to email" do
      assert Reminder.google_method("email") == "email"
    end

    test "maps :sms to popup (SMS degradation)" do
      assert Reminder.google_method(:sms) == "popup"
    end

    test "maps unknown value to popup" do
      assert Reminder.google_method(:other) == "popup"
    end

    test "maps nil to popup" do
      assert Reminder.google_method(nil) == "popup"
    end
  end

  describe "ical_action/1" do
    test "maps :popup to DISPLAY" do
      assert Reminder.ical_action(:popup) == "DISPLAY"
    end

    test "maps :email to EMAIL" do
      assert Reminder.ical_action(:email) == "EMAIL"
    end

    test "maps string email to EMAIL" do
      assert Reminder.ical_action("email") == "EMAIL"
    end

    test "maps :sms to DISPLAY (SMS degradation)" do
      assert Reminder.ical_action(:sms) == "DISPLAY"
    end

    test "maps unknown value to DISPLAY" do
      assert Reminder.ical_action(:other) == "DISPLAY"
    end

    test "maps nil to DISPLAY" do
      assert Reminder.ical_action(nil) == "DISPLAY"
    end
  end

  describe "minutes_before/1" do
    test "reads atom-keyed minutes_before" do
      assert Reminder.minutes_before(%{minutes_before: 15}) == 15
    end

    test "reads string-keyed minutes_before (JSONB round-trip)" do
      assert Reminder.minutes_before(%{"minutes_before" => 30}) == 30
    end

    test "returns nil when key is absent" do
      assert Reminder.minutes_before(%{method: :popup}) == nil
    end

    test "preserves 0 for atom-keyed at-time-of-event reminder" do
      assert Reminder.minutes_before(%{minutes_before: 0}) == 0
    end

    test "preserves 0 for string-keyed at-time-of-event reminder (JSONB round-trip)" do
      assert Reminder.minutes_before(%{"minutes_before" => 0}) == 0
    end
  end

  describe "normalise/1 — zero-minute (at time of event) reminder" do
    test "preserves minutes_before: 0 for atom-keyed map" do
      reminder = %{method: :popup, minutes_before: 0}
      assert Reminder.normalise(reminder) == %{method: :popup, minutes_before: 0}
    end

    test "preserves minutes_before: 0 for string-keyed map (JSONB round-trip)" do
      reminder = %{"method" => "popup", "minutes_before" => 0}
      assert Reminder.normalise(reminder) == %{method: :popup, minutes_before: 0}
    end
  end
end
