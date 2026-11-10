defmodule TymeslotWeb.Components.CoreComponents.DateTimePickerTest do
  use ExUnit.Case, async: true

  @moduletag :ui

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Components.CoreComponents.DateTimePicker
  alias TymeslotWeb.Components.Shared.PickerPreferences

  defp config(html) do
    [encoded] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[phx-hook='DateTimePicker']")
      |> LazyHTML.attribute("data-picker-config")

    Jason.decode!(encoded)
  end

  defp attribute(html, selector, name) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp date(assigns), do: render_component(&DateTimePicker.date_picker/1, assigns)
  defp time(assigns), do: render_component(&DateTimePicker.time_picker/1, assigns)
  defp datetime(assigns), do: render_component(&DateTimePicker.datetime_picker/1, assigns)

  describe "date_picker/1" do
    test "posts the ISO date through a hidden input named like the field" do
      html = date(id: "d", name: "starts_on", value: "2026-11-14", label: "Starts")

      assert ["hidden"] == attribute(html, "[name='starts_on']", "type")
      assert ["2026-11-14"] == attribute(html, "[name='starts_on']", "value")
    end

    test "shows the date in the viewer's language, from the first render" do
      assert ["14 Nov 2026"] ==
               attribute(
                 date(id: "d", name: "n", value: "2026-11-14", label: "L"),
                 "#d",
                 "value"
               )

      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert ["14. Nov 2026"] ==
                 attribute(
                   date(id: "d", name: "n", value: "2026-11-14", label: "L"),
                   "#d",
                   "value"
                 )
      end)
    end

    test "takes a Date struct and a form field" do
      assert ["2026-02-01"] ==
               attribute(
                 date(id: "d", name: "n", value: ~D[2026-02-01], label: "L"),
                 "[name='n']",
                 "value"
               )

      form = to_form(%{"expires_on" => "2026-03-01"}, as: :invite)

      html = date(field: form[:expires_on], label: "Expires")

      assert ["2026-03-01"] == attribute(html, "[name='invite[expires_on]']", "value")
      assert [_id] = attribute(html, "#invite_expires_on", "data-picker-text")
    end

    test "renders the system control for touch, with the same value and no name" do
      html = date(id: "d", name: "n", value: "2026-11-14", label: "L", min: "2026-01-01")

      assert ["date"] == attribute(html, "#d-native", "type")
      assert ["2026-11-14"] == attribute(html, "#d-native", "value")
      assert ["2026-01-01"] == attribute(html, "#d-native", "min")
      assert [] == attribute(html, "#d-native", "name")
    end

    test "gives every picker an accessible name, the one it is passed or a fallback" do
      named = date(id: "d", name: "n", value: "", "aria-label": "Birthday")
      assert named =~ ~s(id="d-label" hidden)
      assert named =~ "Birthday"
      assert ["d-label"] == attribute(named, "#d", "aria-labelledby")

      assert date(id: "d", name: "n", value: "") =~ ">Date</span>"

      labelled = date(id: "d", name: "n", value: "", label: "Start")
      assert ["d"] == attribute(labelled, "label", "for")
    end

    test "puts autofocus on the typed field alone" do
      html = date(id: "d", name: "n", value: "", label: "L", autofocus: true)

      assert [""] == attribute(html, "#d", "autofocus")
      assert [] == attribute(html, "#d-native", "autofocus")
    end

    test "names each panel by its kind, so a field that changes kind gets a new one" do
      assert [_panel] =
               attribute(date(id: "d", name: "n", value: "", label: "L"), "#d-date-panel", "id")

      assert [_panel] =
               attribute(time(id: "d", name: "n", value: "", label: "L"), "#d-time-panel", "id")
    end

    test "marks an error on the control and describes it" do
      html = date(id: "d", name: "n", value: "", label: "L", errors: ["can't be blank"])

      assert ["true"] == attribute(html, "#d", "aria-invalid")
      assert ["d-error"] == attribute(html, "#d", "aria-describedby")
      assert html =~ "can&#39;t be blank"
    end

    test "carries phx attributes onto the hidden input and other attributes onto the field" do
      html =
        date(
          id: "d",
          name: "n",
          value: "",
          label: "L",
          "phx-change": "pick",
          "data-testid": "field"
        )

      assert ["pick"] == attribute(html, "[name='n']", "phx-change")
      assert ["field"] == attribute(html, "#d-field", "data-testid")
    end

    test "the week start is the one passed, else the process's, else Monday" do
      assert %{"weekStart" => 1} = config(date(id: "d", name: "n", value: "", label: "L"))

      html = date(id: "d", name: "n", value: "", label: "L", week_start: :sunday)
      assert %{"weekStart" => 0} = config(html)
      assert html =~ ~s(<th scope="col" abbr="Sunday">)

      PickerPreferences.put_week_start(:sunday)
      assert %{"weekStart" => 0} = config(date(id: "d", name: "n", value: "", label: "L"))
    end
  end

  describe "time_picker/1" do
    test "shows the time in the viewer's clock and posts 24-hour ISO" do
      html = time(id: "t", name: "n", value: "14:30", label: "L", time_format: "12h")

      assert ["2:30 PM"] == attribute(html, "#t", "value")
      assert ["14:30"] == attribute(html, "[name='n']", "value")
    end

    test "offers the quarter hours, labelled in the viewer's clock, valued in 24-hour" do
      %{"timeOptions" => options} =
        config(time(id: "t", name: "n", value: "", label: "L", time_format: "12h"))

      assert length(options) == 96
      assert ["2:30 PM", "14:30"] in options
    end

    test "falls back to the language's clock, and takes the viewer's when set" do
      assert ["2:30 PM"] ==
               attribute(time(id: "t", name: "n", value: "14:30", label: "L"), "#t", "value")

      PickerPreferences.put_time_format("24h")

      assert ["14:30"] ==
               attribute(time(id: "t", name: "n", value: "14:30", label: "L"), "#t", "value")
    end

    test "cuts a Time struct to HH:MM" do
      assert ["14:30"] ==
               attribute(
                 time(id: "t", name: "n", value: ~T[14:30:00], label: "L"),
                 "[name='n']",
                 "value"
               )
    end
  end

  describe "datetime_picker/1" do
    test "shows the two halves and posts one ISO value" do
      html =
        datetime(id: "c", name: "n", value: "2026-11-14T14:30", label: "L", time_format: "24h")

      assert ["14 Nov 2026"] == attribute(html, "#c", "value")
      assert ["14:30"] == attribute(html, "#c-time", "value")
      assert ["2026-11-14T14:30"] == attribute(html, "[name='n']", "value")
      assert ["datetime-local"] == attribute(html, "#c-native", "type")
    end

    test "normalises a NaiveDateTime as datetime-local does" do
      assert ["2026-11-14T14:30"] ==
               attribute(
                 datetime(id: "c", name: "n", value: ~N[2026-11-14 14:30:45], label: "L"),
                 "[name='n']",
                 "value"
               )
    end

    test "names the time half so it is not read as a second copy of the date" do
      html = datetime(id: "c", name: "n", value: "", label: "L")

      assert ["c-label c-time-name"] == attribute(html, "#c-time", "aria-labelledby")
    end
  end
end
