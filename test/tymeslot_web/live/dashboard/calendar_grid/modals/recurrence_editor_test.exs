defmodule TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditorTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :components
  @moduletag :calendar

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.CalendarGrid.Modals.RecurrenceEditor

  # Monday 15 June 2026, 09:00 UTC.
  @monday ~U[2026-06-15 09:00:00Z]
  # Tuesday 13 October 2026, the month's second Tuesday.
  @second_tuesday ~U[2026-10-13 09:00:00Z]

  defp base_assigns(overrides) do
    Map.merge(
      %{
        recurrence_rule: nil,
        start: @monday,
        myself: %Phoenix.LiveComponent.CID{cid: 1},
        change_event: "update_create_recurrence"
      },
      overrides
    )
  end

  defp render_editor(overrides),
    do: render_component(&RecurrenceEditor.recurrence_editor/1, base_assigns(overrides))

  test "renders the frequency selector with all preset options" do
    html = render_editor(%{})

    assert html =~ "Repeat"
    assert html =~ "Does not repeat"
    assert html =~ "Daily"
    assert html =~ "Weekly"
    assert html =~ "Monthly"
    assert html =~ "Yearly"
    assert html =~ ~s(phx-change="update_create_recurrence")
  end

  test "hides the detail controls when there is no rule" do
    html = render_editor(%{})

    refute html =~ ~s(name="interval")
    refute html =~ ~s(name="end_type")
  end

  test "reveals weekday toggles and end conditions for a weekly rule" do
    html = render_editor(%{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE"})

    assert html =~ ~s(name="by_day[]")
    assert html =~ ~s(name="interval")
    assert html =~ ~s(name="end_type")
    assert html =~ ~r/value="mo"[^>]*checked/
    assert html =~ ~r/value="we"[^>]*checked/
    refute html =~ ~r/value="tu"[^>]*checked/
  end

  test "shows a human-readable summary of the current rule" do
    assert render_editor(%{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE"}) =~
             "Repeats weekly on Mon, Wed"
  end

  for {locale, expected} <- [
        {"fr", ~w(Lun. Mar. Mer. Jeu. Ven. Sam. Dim.)},
        {"pl", ~w(Pon. Wt. Śr. Czw. Pt. Sob. Niedz.)}
      ] do
    test "#{locale}: starts each weekday toggle with a capital, as a label of its own" do
      html =
        Gettext.with_locale(TymeslotWeb.Gettext, unquote(locale), fn ->
          render_editor(%{recurrence_rule: "FREQ=WEEKLY;BYDAY=MO,WE"})
        end)

      labels =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("label:has(input[name='by_day[]'])")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert labels == unquote(expected)
    end
  end

  describe "a monthly or yearly rule" do
    test "offers the start's day and the positions the start is" do
      html = render_editor(%{recurrence_rule: "FREQ=MONTHLY;BYDAY=2TU", start: @second_tuesday})

      assert html =~ ~r/<option value="day">\s*on day 13\s*<\/option>/
      assert html =~ ~r/<option value="2:tu" selected[^>]*>\s*on the second Tuesday\s*<\/option>/
      refute html =~ ~s(value="-1:tu")
      assert html =~ "To repeat on another day, move the event to that day."
      assert html =~ "Repeats monthly on the second Tuesday"
    end

    test "offers a yearly pattern its positions in the start's month" do
      html = render_editor(%{recurrence_rule: "FREQ=YEARLY", start: @second_tuesday})

      assert html =~ ~r/<option value="day" selected[^>]*>\s*on 13 October\s*<\/option>/
      assert html =~ "on the second Tuesday of October"
      assert html =~ "Repeats yearly on 13 October"
    end
  end

  describe "a rule the editor cannot build" do
    test "is shown, with an action to replace it, and no controls" do
      html =
        render_editor(%{
          recurrence_rule: "FREQ=MONTHLY;BYDAY=MO,TU;BYSETPOS=1,-1",
          start: @second_tuesday
        })

      assert html =~ "Repeats on a custom pattern"
      assert html =~ "Replace repeat rule"

      assert html =~
               ~r/<form[^>]*id="recurrence-editor-form-update_create_recurrence"[^>]*class="space-y-2 hidden"/
    end
  end

  describe "the end date the organiser picked comes back unchanged" do
    # A timed rule's UNTIL is a UTC instant, and end of day on 30 June in Los
    # Angeles is 1 July in UTC. Reading it back without the timezone would put
    # 1 July in the date input the organiser set to 30 June.
    test "a timed UNTIL is shown as the local date it ends" do
      html =
        render_editor(%{
          recurrence_rule: "FREQ=DAILY;UNTIL=20260701T065959Z",
          timezone: "America/Los_Angeles",
          start: DateTime.new!(~D[2026-06-01], ~T[09:00:00], "America/Los_Angeles")
        })

      assert html =~ ~s(name="until" value="2026-06-30")
      assert html =~ "Repeats daily until 30 June 2026"
    end

    test "an all-day UNTIL is zone-free and shown as it is written" do
      html =
        render_editor(%{
          recurrence_rule: "FREQ=DAILY;UNTIL=20260630",
          timezone: "America/Los_Angeles",
          start: ~D[2026-06-01]
        })

      assert html =~ ~s(name="until" value="2026-06-30")
    end
  end

  describe "summary/2" do
    # Mid-sentence, a weekday keeps the case its language writes it in.
    test "names the weekly days as the locale abbreviates them mid-sentence" do
      rule = "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=10"

      Gettext.with_locale(TymeslotWeb.Gettext, "fr", fn ->
        assert RecurrenceEditor.summary(rule, @monday) ==
                 "Se répète chaque semaine les lun., mer. 10 fois"
      end)

      Gettext.with_locale(TymeslotWeb.Gettext, "pl", fn ->
        assert RecurrenceEditor.summary(rule, @monday) ==
                 "Powtarza się co tydzień (pon., śr.) łącznie 10 razy"
      end)

      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert RecurrenceEditor.summary(rule, @monday) ==
                 "Wiederholt sich wöchentlich jeweils Mo, Mi insgesamt 10-mal"
      end)
    end

    test "summarises a simple weekly rule" do
      assert RecurrenceEditor.summary("FREQ=WEEKLY;BYDAY=MO,WE", @monday) ==
               "Repeats weekly on Mon, Wed"
    end

    test "summarises an interval and count" do
      assert RecurrenceEditor.summary("FREQ=DAILY;INTERVAL=2;COUNT=5", @monday) ==
               "Repeats every 2 days for 5 occurrences"
    end

    test "summarises an until date, written out as the locale writes dates" do
      rule = "FREQ=WEEKLY;UNTIL=20261231"

      assert RecurrenceEditor.summary(rule, ~D[2026-06-15]) ==
               "Repeats weekly on Mon until 31 December 2026"

      Gettext.with_locale(TymeslotWeb.Gettext, "it", fn ->
        assert RecurrenceEditor.summary("FREQ=YEARLY", ~D[2026-10-01]) =~ "il giorno 1° ottobre"
      end)

      Gettext.with_locale(TymeslotWeb.Gettext, "pt", fn ->
        assert RecurrenceEditor.summary("FREQ=YEARLY", ~D[2026-10-01]) =~ "no dia 1º de outubro"
      end)

      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert RecurrenceEditor.summary(rule, ~D[2026-06-15]) ==
                 "Wiederholt sich wöchentlich jeweils Mo bis 31. Dezember 2026"
      end)
    end

    # The ordinal agrees with the weekday: Tuesday is masculine in Polish,
    # Wednesday feminine.
    test "summarises a position as one phrase, agreeing with its weekday" do
      Gettext.with_locale(TymeslotWeb.Gettext, "pl", fn ->
        assert RecurrenceEditor.summary("FREQ=MONTHLY;BYDAY=2TU", @second_tuesday) =~
                 "w drugi wtorek"

        assert RecurrenceEditor.summary("FREQ=MONTHLY;BYDAY=2WE", ~D[2026-10-14]) =~
                 "w drugą środę"
      end)
    end

    test "writes the first of a month as an ordinal in French, Italian and Portuguese only" do
      Gettext.with_locale(TymeslotWeb.Gettext, "fr", fn ->
        assert RecurrenceEditor.summary("FREQ=MONTHLY;UNTIL=20270101", ~D[2026-10-01]) =~
                 "le 1er du mois jusqu’au 1er janvier 2027"

        assert RecurrenceEditor.summary("FREQ=YEARLY", ~D[2026-10-01]) =~ "le 1er octobre"
        assert RecurrenceEditor.summary("FREQ=MONTHLY", ~D[2026-10-02]) =~ "le 2 du mois"
      end)

      Gettext.with_locale(TymeslotWeb.Gettext, "de", fn ->
        assert RecurrenceEditor.summary("FREQ=YEARLY;UNTIL=20270101", ~D[2026-10-01]) =~
                 "1. Oktober"
      end)

      assert RecurrenceEditor.summary("FREQ=YEARLY", ~D[2026-10-01]) =~ "on 1 October"
    end

    test "returns nil for a non-recurring rule" do
      assert RecurrenceEditor.summary(nil, @monday) == nil
    end
  end
end
