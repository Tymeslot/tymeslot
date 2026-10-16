defmodule Tymeslot.AppSettings.EnvPins do
  @moduledoc """
  Decides which admin-editable settings an environment variable fixes.

  Called from `config/runtime.exs` with the process environment, so it must
  stay pure: no Application env, no Repo, no Logger.

  A variable pins its setting only when its value is one the variable's own
  parse in `config/runtime.exs` explicitly recognises. Those parses are
  strict (`REGISTRATION_ENABLED == "true"`, a `Float.parse/1` with a
  fallback), so a value such as `1` or `abc` is silently read as something
  the operator did not mean; pinning it as well would stop the admin settings
  page from correcting it. Such a value is reported as unrecognised instead,
  leaving the setting as it was before pins existed: the strictly parsed
  config value, which a value saved on the admin page still overrides.

  Values are compared untrimmed, as the parses read them: `"true "` is not
  `"true"` to them, so it is not recognised here either. Blank counts as
  unset.
  """

  @booleans ~w(true false)
  @boolean_words ~w(true 1 yes false 0 no)

  # {setting key, environment variable, the values its parse recognises}
  @settings [
    {:registration_enabled, "REGISTRATION_ENABLED", :boolean},
    {:password_auth_enabled, "PASSWORD_AUTH_ENABLED", :boolean},
    {:google_auth_enabled, "ENABLE_GOOGLE_AUTH", :boolean},
    {:github_auth_enabled, "ENABLE_GITHUB_AUTH", :boolean},
    # Any other value raises in runtime.exs, so whatever reaches here is valid.
    {:oauth_auth_enabled, "ENABLE_OAUTH_AUTH", :any},
    {:recaptcha_signup_enabled, "RECAPTCHA_SIGNUP_ENABLED", :boolean},
    {:recaptcha_booking_enabled, "RECAPTCHA_BOOKING_ENABLED", :boolean},
    {:recaptcha_signup_min_score, "RECAPTCHA_SIGNUP_MIN_SCORE", :score},
    {:recaptcha_booking_min_score, "RECAPTCHA_BOOKING_MIN_SCORE", :score},
    {:admin_alerts_enabled, "ADMIN_ALERTS_ENABLED", :boolean_word},
    {:admin_alert_email, "ADMIN_ALERT_EMAIL", :any},
    {:meeting_payments_enabled, "MEETING_PAYMENTS_ENABLED", :boolean_word_any_case}
  ]

  @typedoc "A set variable whose value does not pin its setting."
  @type unrecognised :: %{var: String.t(), value: String.t(), accepted: String.t()}

  @doc """
  Splits the set variables in `env` (as `System.get_env/0` returns it) into
  the pins, `%{setting_key => "ENV_VAR"}`, and the unrecognised values, in
  the order the settings are listed.
  """
  @spec from_env(%{String.t() => String.t()}) :: {%{atom() => String.t()}, [unrecognised()]}
  def from_env(env) do
    {pins, unrecognised} =
      for {key, var, rule} <- @settings,
          value = Map.get(env, var, ""),
          String.trim(value) != "",
          reduce: {%{}, []} do
        {pins, unrecognised} ->
          if recognised?(rule, value),
            do: {Map.put(pins, key, var), unrecognised},
            else: {pins, [%{var: var, value: value, accepted: accepted(rule)} | unrecognised]}
      end

    {pins, Enum.reverse(unrecognised)}
  end

  defp recognised?(:any, _value), do: true
  defp recognised?(:boolean, value), do: value in @booleans
  defp recognised?(:boolean_word, value), do: value in @boolean_words
  defp recognised?(:boolean_word_any_case, value), do: String.downcase(value) in @boolean_words

  defp recognised?(:score, value) do
    case Float.parse(value) do
      {score, ""} -> score >= 0.0 and score <= 1.0
      _other -> false
    end
  end

  defp accepted(:boolean), do: "true or false"
  defp accepted(:boolean_word), do: "true, 1, yes, false, 0 or no"
  defp accepted(:boolean_word_any_case), do: "true, 1, yes, false, 0 or no, in any case"
  defp accepted(:score), do: "a number from 0.0 to 1.0"
end
