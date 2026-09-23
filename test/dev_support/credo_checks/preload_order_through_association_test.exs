Code.require_file(
  "dev_support/credo_checks/preload_order_through_association.ex",
  Path.join(__DIR__, "../../..")
)

defmodule CredoChecks.PreloadOrderThroughAssociationTest do
  use Credo.Test.Case, async: false

  alias CredoChecks.PreloadOrderThroughAssociation

  @moduletag :dev_support

  setup_all do
    Application.ensure_all_started(:credo)
    :ok
  end

  describe "flagged cases" do
    test "flags preload_order alongside through on has_many" do
      """
      defmodule Tymeslot.Schedule do
        use Ecto.Schema

        schema "schedules" do
          has_many :slots, through: [:schedule_days, :slots], preload_order: [asc: :starts_at]
        end
      end
      """
      |> to_source_file("lib/tymeslot/schedule.ex")
      |> run_check(PreloadOrderThroughAssociation)
      |> assert_issue(fn issue -> assert issue.trigger == "has_many" end)
    end

    test "flags preload_order alongside through on has_one" do
      """
      defmodule Tymeslot.Schedule do
        use Ecto.Schema

        schema "schedules" do
          has_one :latest_slot, through: [:schedule_days, :latest_slot], preload_order: [desc: :starts_at]
        end
      end
      """
      |> to_source_file("lib/tymeslot/schedule.ex")
      |> run_check(PreloadOrderThroughAssociation)
      |> assert_issue(fn issue -> assert issue.trigger == "has_one" end)
    end
  end

  describe "accepted cases" do
    test "accepts preload_order without through" do
      """
      defmodule Tymeslot.ScheduleDay do
        use Ecto.Schema

        schema "schedule_days" do
          has_many :slots, Tymeslot.Slot, preload_order: [asc: :starts_at]
        end
      end
      """
      |> to_source_file("lib/tymeslot/schedule_day.ex")
      |> run_check(PreloadOrderThroughAssociation)
      |> refute_issues()
    end

    test "accepts through without preload_order" do
      """
      defmodule Tymeslot.Schedule do
        use Ecto.Schema

        schema "schedules" do
          has_many :slots, through: [:schedule_days, :slots]
        end
      end
      """
      |> to_source_file("lib/tymeslot/schedule.ex")
      |> run_check(PreloadOrderThroughAssociation)
      |> refute_issues()
    end

    test "accepts a plain has_many with no options" do
      """
      defmodule Tymeslot.ScheduleDay do
        use Ecto.Schema

        schema "schedule_days" do
          has_many :slots, Tymeslot.Slot
        end
      end
      """
      |> to_source_file("lib/tymeslot/schedule_day.ex")
      |> run_check(PreloadOrderThroughAssociation)
      |> refute_issues()
    end

    test "ignores the combination outside lib/" do
      """
      defmodule Tymeslot.ScheduleTest do
        use Ecto.Schema

        schema "schedules" do
          has_many :slots, through: [:schedule_days, :slots], preload_order: [asc: :starts_at]
        end
      end
      """
      |> to_source_file("test/tymeslot/schedule_test.exs")
      |> run_check(PreloadOrderThroughAssociation)
      |> refute_issues()
    end
  end
end
