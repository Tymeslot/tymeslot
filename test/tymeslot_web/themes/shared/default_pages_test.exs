defmodule TymeslotWeb.Themes.Shared.DefaultPagesTest do
  @moduledoc """
  The pages a theme gets from `use TymeslotWeb.Themes.Core.Theme,
  page_shell: ...`: each shared body inside the theme's shell, the shell
  told which page it is drawing.
  """

  use ExUnit.Case, async: true

  @moduletag :themes

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias TymeslotWeb.Test.FixtureTheme.Theme, as: FixtureTheme
  alias TymeslotWeb.ThemeCommonTestCases

  defp assigns, do: Map.put(ThemeCommonTestCases.build_meeting_assigns("99"), :theme_id, "99")

  defp meeting(action, assigns \\ assigns()),
    do: render_component(&FixtureTheme.render_meeting_action(&1, action), assigns)

  defp payment(page, assigns),
    do: render_component(&FixtureTheme.render_payment_page(&1, page), assigns)

  test "draws each meeting page inside the theme's shell, naming the page" do
    for {action, page} <- [
          reschedule: "reschedule",
          cancel: "cancel",
          cancel_confirmed: "cancel_confirmed"
        ] do
      out = meeting(action)
      assert out =~ ~s(data-testid="fixture-page-shell"), "#{action} is not in the shell"
      assert out =~ ~s(data-page="#{page}")
      assert out =~ ~s(class="manage-page manage-page--)
    end
  end

  test "the cancel page sends the dispatcher's events" do
    out = meeting(:cancel)
    assert out =~ ~s(phx-click="cancel_meeting")
    assert out =~ ~s(phx-click="keep_meeting")
    assert out =~ ~s(data-testid="cancel-meeting")
  end

  test "the reschedule page leads to the organiser's booking page for this meeting" do
    out = meeting(:reschedule, Map.put(assigns(), :meeting_uid, "m-42"))

    assert out =~ "/testuser?locale=en&amp;reschedule_meeting_uid=m-42"
  end

  test "the payment pages carry the theme's own test id, from the page's theme" do
    base = %{loading: true, payment: nil, meeting: nil, rebook_path: nil, theme_id: "99"}

    assert payment(:processing, base) =~
             ~s(data-testid="fixture-payment-processing")

    assert payment(:cancelled, base) =~
             ~s(data-testid="fixture-payment-cancelled")
  end

  test "a payment page without a locale or customisation gets neither" do
    base = %{loading: false, payment: nil, meeting: nil, rebook_path: "/x", theme_id: "99"}
    out = payment(:cancelled, base)

    assert out =~ ~s(data-page="payment_cancelled")
    refute out =~ "<style"
  end

  test "the payment pages show the language switcher, as the meeting pages do" do
    base = %{
      loading: true,
      payment: nil,
      meeting: nil,
      rebook_path: nil,
      theme_id: "99",
      locale: "en",
      language_dropdown_open: false
    }

    for page <- [:processing, :cancelled] do
      assert payment(page, base) =~ ~s(id="language-switcher-dropdown"),
             "the #{page} page has no language switcher"
    end

    assert meeting(:cancel, Map.merge(assigns(), %{locale: "en", language_dropdown_open: false})) =~
             ~s(id="language-switcher-dropdown")
  end

  test "the payment pages open with the meeting pages' status icon" do
    base = %{loading: true, payment: nil, meeting: nil, rebook_path: nil, theme_id: "99"}

    assert payment(:processing, base) =~ "manage-page__icon manage-page__icon--primary"
    assert payment(:cancelled, base) =~ "manage-page__icon manage-page__icon--danger"
    assert meeting(:cancel) =~ "manage-page__icon manage-page__icon--danger"
  end

  test "the confirmed date sits in its own span, inside the sentence" do
    meeting = %{
      start_time: ~U[2027-03-03 09:00:00Z],
      attendee_timezone: "Europe/Berlin",
      status: :confirmed
    }

    payment = %{status: :paid}

    out =
      payment(:processing, %{
        loading: false,
        payment: payment,
        meeting: meeting,
        rebook_path: nil,
        theme_id: "99"
      })

    assert out =~ "manage-page__icon--success"

    assert out =~
             ~r{confirmed for <span class="payment-page-date">3 March 2027 at [^<]+ CET</span>\.}
  end

  # The date is put into the sentence after it is translated, so the article
  # Italian puts before it, elided before a day read with a vowel, is put in
  # with it; an amount takes none.
  test "an Italian confirmed date carries its article inside its span, the amount none" do
    Gettext.put_locale(TymeslotWeb.Gettext, "it")

    meeting = %{
      start_time: ~U[2027-03-08 09:00:00Z],
      attendee_timezone: "Europe/Rome",
      status: :confirmed
    }

    out =
      payment(:processing, %{
        loading: false,
        payment: %{status: :paid, amount_cents: 800, currency: "eur"},
        meeting: meeting,
        rebook_path: nil,
        theme_id: "99"
      })

    assert out =~
             ~r{confermata per <span class="payment-page-date">l&#39;8 marzo 2027 alle 10:00 CET</span>\.}

    assert out =~ "Pagato: <span class=\"payment-page-date\">8,00\u00A0€</span>"
  end

  test "an unknown meeting action raises as the conventional default does" do
    assert_raise RuntimeError, "Unsupported meeting action: invalid", fn ->
      FixtureTheme.render_meeting_action(assigns(), :invalid)
    end
  end
end
