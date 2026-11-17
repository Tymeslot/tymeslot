defmodule TymeslotWeb.Dashboard.Availability.TimeOffFormTest do
  @moduledoc """
  Covers the time-off form's data: the date bounds it opens with, for a new
  period and for a stored one outside them, the attributes it reads from a
  submitted form, and which of the changeset's messages it shows while the
  form is being filled in.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability

  import Tymeslot.Factory

  alias Tymeslot.Validation.Constraints
  alias TymeslotWeb.Dashboard.Availability.TimeOffForm

  @today ~D[2026-09-01]

  describe "blank/1" do
    test "bounds both pickers from today to the furthest last day allowed" do
      last_day = @today |> Constraints.time_off_last_end_date() |> Date.to_iso8601()

      assert %{
               mode: :create,
               min_starts_on: "2026-09-01",
               min_ends_on: "2026-09-01",
               max_starts_on: ^last_day,
               max_ends_on: ^last_day,
               starts_on: "",
               label: ""
             } = TimeOffForm.blank(@today)
    end
  end

  describe "edit/2" do
    test "reaches the bounds out to stored dates that fall outside them" do
      last_day = Constraints.time_off_last_end_date(@today)
      beyond = Date.add(last_day, 10)

      period = insert(:time_off_period, starts_on: ~D[2026-08-20], ends_on: beyond)

      data = TimeOffForm.edit(period, @today)

      assert data.min_starts_on == "2026-08-20"
      assert data.min_ends_on == "2026-09-01"
      assert data.max_starts_on == Date.to_iso8601(last_day)
      assert data.max_ends_on == Date.to_iso8601(beyond)
      assert data.starts_on == "2026-08-20"
      assert data.ends_on == Date.to_iso8601(beyond)
    end

    test "carries the stored times in the 24-hour wire format" do
      period =
        insert(:time_off_period,
          starts_on: ~D[2026-09-10],
          ends_on: ~D[2026-09-12],
          start_time: ~T[14:30:00],
          end_time: nil
        )

      assert %{mode: :edit, start_time: "14:30", end_time: ""} = TimeOffForm.edit(period, @today)
    end
  end

  describe "attrs_from/1" do
    test "trims every form field and reads a missing or non-string one as blank" do
      assert TimeOffForm.attrs_from(%{
               "starts_on" => " 2026-09-10 ",
               "ends_on" => ["2026-09-12"],
               "label" => "Away",
               "ignored" => "x"
             }) == %{
               starts_on: "2026-09-10",
               ends_on: "",
               start_time: "",
               end_time: "",
               label: "Away"
             }
    end
  end

  describe "validate/4" do
    setup do
      %{profile: insert(:profile, timezone: "Etc/UTC")}
    end

    test "flags a backwards range beside the last day", %{profile: profile} do
      attrs =
        TimeOffForm.attrs_from(%{"starts_on" => "2026-09-12", "ends_on" => "2026-09-10"})

      data = TimeOffForm.validate(TimeOffForm.blank(@today), attrs, profile.id, @today)

      assert {"must not be before the start date", _opts} = data.errors.ends_on
      assert data.starts_on == "2026-09-12"
    end

    test "reports nothing for a field not filled in yet", %{profile: profile} do
      attrs = TimeOffForm.attrs_from(%{"starts_on" => "2026-09-12"})

      data = TimeOffForm.validate(TimeOffForm.blank(@today), attrs, profile.id, @today)

      assert data.errors == %{}
    end
  end
end
