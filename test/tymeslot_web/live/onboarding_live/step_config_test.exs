defmodule TymeslotWeb.OnboardingLive.StepConfigTest do
  @moduledoc """
  Tests for the onboarding step sequence and where a host resumes it.
  """

  use ExUnit.Case, async: true
  @moduletag :onboarding

  alias TymeslotWeb.OnboardingLive.StepConfig

  describe "steps/0" do
    test "is the five steps in order" do
      assert StepConfig.steps() == [:profile, :connect_calendar, :meeting, :choose_theme, :ready]
    end

    test "every step has a title and a progress label" do
      assert Enum.map(StepConfig.steps(), &StepConfig.step_title/1) ==
               ["Your link", "Your calendar", "Your meeting", "Your look", "You're live"]

      assert Enum.map(StepConfig.steps(), &StepConfig.progress_label/1) ==
               ["Link", "Calendar", "Meeting", "Look", "Live"]
    end
  end

  describe "resume_step/1" do
    test "a host without a username resumes at the link" do
      assert StepConfig.resume_step(%{username: nil, bookable_calendar?: true}) == :profile
      assert StepConfig.resume_step(%{username: "", bookable_calendar?: false}) == :profile
    end

    test "a host with a username but no bookable calendar resumes at the calendar" do
      assert StepConfig.resume_step(%{username: "ada", bookable_calendar?: false}) ==
               :connect_calendar
    end

    test "a host with a username and a bookable calendar resumes at the meeting" do
      assert StepConfig.resume_step(%{
               username: "ada",
               bookable_calendar?: true,
               meeting_confirmed?: false
             }) == :meeting
    end

    test "a host who has confirmed the meeting resumes at the look" do
      assert StepConfig.resume_step(%{
               username: "ada",
               bookable_calendar?: true,
               meeting_confirmed?: true
             }) == :choose_theme
    end

    test "a confirmed meeting does not open anything a calendar has to open first" do
      assert StepConfig.resume_step(%{
               username: "ada",
               bookable_calendar?: false,
               meeting_confirmed?: true
             }) == :connect_calendar
    end
  end

  describe "reachable?/2" do
    test "steps past the link or the calendar are out of reach until it is done" do
      assert StepConfig.reachable?(:profile, :connect_calendar)
      assert StepConfig.reachable?(:connect_calendar, :connect_calendar)
      refute StepConfig.reachable?(:meeting, :connect_calendar)
      refute StepConfig.reachable?(:choose_theme, :connect_calendar)
      refute StepConfig.reachable?(:connect_calendar, :profile)
      refute StepConfig.reachable?(:ready, :connect_calendar)
      refute StepConfig.reachable?(:ready, :profile)
    end

    test "the look and the live step wait for the meeting" do
      assert StepConfig.reachable?(:connect_calendar, :meeting)
      assert StepConfig.reachable?(:meeting, :meeting)
      refute StepConfig.reachable?(:choose_theme, :meeting)
      refute StepConfig.reachable?(:ready, :meeting)
    end

    test "every step is reachable once the host resumes at the look" do
      assert Enum.all?(StepConfig.steps(), &StepConfig.reachable?(&1, :choose_theme))
    end
  end

  describe "next_step/1 and previous_step/1" do
    test "walk the sequence and stop at its ends" do
      assert StepConfig.next_step(:connect_calendar) == :meeting
      assert StepConfig.next_step(:ready) == nil
      assert StepConfig.previous_step(:choose_theme) == :meeting
      assert StepConfig.previous_step(:profile) == nil
    end
  end

  describe "valid_step?/1" do
    test "accepts the five step names and refuses retired ones" do
      assert Enum.all?(
               ~w(profile connect_calendar meeting choose_theme ready),
               &StepConfig.valid_step?/1
             )

      refute Enum.any?(
               ~w(welcome buffer_time booking_window minimum_notice),
               &StepConfig.valid_step?/1
             )
    end
  end

  describe "navigation buttons" do
    test "Back is hidden on the first step only" do
      assert Enum.reject(StepConfig.steps(), &StepConfig.show_back_button?/1) == [:profile]
    end

    test "Continue reads the same on every step but the last" do
      assert StepConfig.steps()
             |> List.delete(:ready)
             |> Enum.map(&StepConfig.next_button_text/1)
             |> Enum.uniq() == ["Continue"]
    end
  end
end
