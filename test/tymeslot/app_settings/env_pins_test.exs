defmodule Tymeslot.AppSettings.EnvPinsTest do
  @moduledoc """
  An environment variable pins its admin setting only when its value is one
  the variable's own parse in `config/runtime.exs` recognises; any other
  value is reported instead, so the admin settings page can still correct it.
  """

  use ExUnit.Case, async: true

  @moduletag :infrastructure

  alias Tymeslot.AppSettings.EnvPins

  defp pins(env), do: env |> EnvPins.from_env() |> elem(0)
  defp unrecognised(env), do: env |> EnvPins.from_env() |> elem(1)

  describe "true/false variables" do
    test "true and false pin the setting" do
      assert pins(%{"REGISTRATION_ENABLED" => "true", "PASSWORD_AUTH_ENABLED" => "false"}) ==
               %{
                 registration_enabled: "REGISTRATION_ENABLED",
                 password_auth_enabled: "PASSWORD_AUTH_ENABLED"
               }
    end

    test "values the parse reads as false do not pin, and are reported" do
      for value <- ["1", "TRUE", "yes", "true "] do
        assert EnvPins.from_env(%{"ENABLE_GOOGLE_AUTH" => value}) ==
                 {%{}, [%{var: "ENABLE_GOOGLE_AUTH", value: value, accepted: "true or false"}]}
      end
    end
  end

  describe "ADMIN_ALERTS_ENABLED" do
    test "true/1/yes and false/0/no pin the setting" do
      for value <- ~w(true 1 yes false 0 no) do
        assert pins(%{"ADMIN_ALERTS_ENABLED" => value}) == %{
                 admin_alerts_enabled: "ADMIN_ALERTS_ENABLED"
               }
      end
    end

    test "is case-sensitive, as its parse is" do
      assert [%{var: "ADMIN_ALERTS_ENABLED", value: "Yes"}] =
               unrecognised(%{"ADMIN_ALERTS_ENABLED" => "Yes"})
    end
  end

  describe "MEETING_PAYMENTS_ENABLED" do
    test "accepts the same words in any case, as its parse downcases" do
      for value <- ~w(TRUE Yes 1 False NO 0) do
        assert pins(%{"MEETING_PAYMENTS_ENABLED" => value}) ==
                 %{meeting_payments_enabled: "MEETING_PAYMENTS_ENABLED"}
      end
    end

    test "rejects anything else" do
      assert [%{var: "MEETING_PAYMENTS_ENABLED"}] =
               unrecognised(%{"MEETING_PAYMENTS_ENABLED" => "on"})
    end
  end

  describe "reCAPTCHA minimum scores" do
    test "a number from 0.0 to 1.0 pins the setting" do
      for value <- ["0", "0.5", "1", "1.0"] do
        assert pins(%{"RECAPTCHA_SIGNUP_MIN_SCORE" => value}) ==
                 %{recaptcha_signup_min_score: "RECAPTCHA_SIGNUP_MIN_SCORE"}
      end
    end

    test "unparseable, partly parsed or out-of-range values are reported" do
      for value <- ["abc", "0.5abc", "5", "-0.1", " 0.5"] do
        assert unrecognised(%{"RECAPTCHA_BOOKING_MIN_SCORE" => value}) == [
                 %{
                   var: "RECAPTCHA_BOOKING_MIN_SCORE",
                   value: value,
                   accepted: "a number from 0.0 to 1.0"
                 }
               ]
      end
    end
  end

  test "ENABLE_OAUTH_AUTH and ADMIN_ALERT_EMAIL pin on any non-blank value" do
    assert pins(%{"ENABLE_OAUTH_AUTH" => "true", "ADMIN_ALERT_EMAIL" => "ops@example.com"}) == %{
             oauth_auth_enabled: "ENABLE_OAUTH_AUTH",
             admin_alert_email: "ADMIN_ALERT_EMAIL"
           }
  end

  test "blank and unset variables neither pin nor are reported" do
    assert EnvPins.from_env(%{"REGISTRATION_ENABLED" => "  ", "ADMIN_ALERT_EMAIL" => ""}) ==
             {%{}, []}
  end

  test "unrelated variables are ignored" do
    assert EnvPins.from_env(%{"PATH" => "/usr/bin"}) == {%{}, []}
  end
end
