defmodule TymeslotWeb.Themes.Shared.Components.BookingFormTest do
  @moduledoc """
  The shared booking form: the contact fields a booking needs and the
  anti-spam markup a theme must not be able to leave out.
  """

  use ExUnit.Case, async: false

  @moduletag :bookings
  @moduletag :security

  import Phoenix.Component, only: [sigil_H: 2, to_form: 2]
  import Phoenix.LiveViewTest

  alias TymeslotWeb.Themes.Shared.Components.BookingForm

  setup do
    old_cfg = Application.get_env(:tymeslot, :recaptcha, [])
    old_env = Map.new(~w(RECAPTCHA_SITE_KEY RECAPTCHA_SECRET_KEY), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Application.put_env(:tymeslot, :recaptcha, old_cfg)

      Enum.each(old_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  defp render_form(extra \\ %{}) do
    assigns =
      Map.merge(
        %{
          form: to_form(%{}, as: :booking),
          validation_errors: %{},
          target: nil
        },
        extra
      )

    render_component(&BookingForm.booking_form/1, assigns)
  end

  # As booking_recaptcha_test.exs enables it: `RecaptchaHelpers.booking_active?/0`
  # needs the flag, a site key and a secret key.
  defp enable_recaptcha do
    Application.put_env(:tymeslot, :recaptcha,
      booking_enabled: true,
      booking_action: "booking_form"
    )

    System.put_env("RECAPTCHA_SITE_KEY", "test_site_key")
    System.put_env("RECAPTCHA_SECRET_KEY", "test_secret_key")
  end

  test "renders the honeypot inside the form, hidden from people" do
    doc = Floki.parse_document!(render_form())

    assert [_input] =
             Floki.find(
               doc,
               "form#booking-form .honeypot-field[aria-hidden] input[name='booking[website]'][tabindex='-1']"
             )
  end

  test "renders the contact fields the submit validates" do
    doc = Floki.parse_document!(render_form())

    for name <- ["booking[name]", "booking[email]", "booking[message]"] do
      assert [_field] = Floki.find(doc, "form#booking-form [name='#{name}']"), "no #{name}"
    end

    assert [_form] =
             Floki.find(
               doc,
               "form#booking-form[phx-submit='submit'][phx-change='validate'][novalidate]"
             )
  end

  test "with reCAPTCHA on, carries the hook, the token input and the notice" do
    enable_recaptcha()
    doc = Floki.parse_document!(render_form())

    assert [_form] =
             Floki.find(
               doc,
               "form#booking-form[phx-hook='RecaptchaV3'][data-site-key='test_site_key']"
             )

    assert [_token] =
             Floki.find(
               doc,
               "form#booking-form input[type='hidden'][name='booking[g-recaptcha-response]']"
             )

    assert [_notice] = Floki.find(doc, ".recaptcha-notice")
  end

  test "with reCAPTCHA off, renders none of it" do
    Application.put_env(:tymeslot, :recaptcha, booking_enabled: false)
    doc = Floki.parse_document!(render_form())

    assert Floki.find(doc, "form#booking-form[phx-hook]") == []
    assert Floki.find(doc, "[name='booking[g-recaptcha-response]']") == []
    assert Floki.find(doc, ".recaptcha-notice") == []
  end

  test "renders its inner block after the form and before the notice" do
    enable_recaptcha()

    html =
      render_component(
        fn assigns ->
          ~H"""
          <BookingForm.booking_form form={@form} validation_errors={%{}} target={nil}>
            <p id="between">guests</p>
          </BookingForm.booking_form>
          """
        end,
        %{form: to_form(%{}, as: :booking)}
      )

    [form_at, between_at, notice_at] =
      Enum.map(["id=\"booking-form\"", "id=\"between\"", "recaptcha-notice"], fn needle ->
        {at, _len} = :binary.match(html, needle)
        at
      end)

    assert form_at < between_at and between_at < notice_at
  end

  test "wraps name and email only when a theme asks for it" do
    wrapped = Floki.parse_document!(render_form(%{contact_class: "booking-inline-fields"}))
    assert [_n] = Floki.find(wrapped, ".booking-inline-fields [name='booking[name]']")
    assert [_e] = Floki.find(wrapped, ".booking-inline-fields [name='booking[email]']")
    assert Floki.find(wrapped, ".booking-inline-fields [name='booking[message]']") == []

    # Without the option there is no wrapper: the form's direct children are
    # the honeypot, the three fields' own wrappers and the token input, as in
    # Rhythm today.
    plain = Floki.parse_document!(render_form())
    wrapped_count = wrapped |> Floki.find("form#booking-form > *") |> length()
    assert plain |> Floki.find("form#booking-form > *") |> length() == wrapped_count + 1
  end

  test "suggests a Czech name and a matching address in Czech" do
    doc =
      Gettext.with_locale(TymeslotWeb.Gettext, "cs", fn ->
        Floki.parse_document!(render_form())
      end)

    assert ["Jan Novák"] =
             doc |> Floki.find("[name='booking[name]']") |> Floki.attribute("placeholder")

    assert ["jan@example.com"] =
             doc |> Floki.find("[name='booking[email]']") |> Floki.attribute("placeholder")
  end
end
