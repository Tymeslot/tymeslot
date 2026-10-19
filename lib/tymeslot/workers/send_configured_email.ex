defmodule Tymeslot.Workers.SendConfiguredEmail do
  @moduledoc """
  Sends an email built by a template the deployment configures (the
  `:refund_processed_template` and friends a payment webhook names), from a
  job, so a mail outage delays it rather than losing it.

  The webhook enqueues and returns; this job builds the email when it runs,
  for the user it names (loaded fresh, with their profile) or for an address,
  and delivers it through `TransactionalEmailDelivery`: an open mail circuit
  snoozes the job without spending an attempt, a permanently rejected
  address discards it, and any other failure retries. The send is claimed,
  so a job the lifeline rescues after it went out does not send it again.

  Only allowed template functions run: the payment templates' own, plus
  those the deployment lists in `:extra_configured_email_templates`. Both
  `enqueue/4` and the job check the pair, so a job row naming anything else
  is discarded rather than applied.

  The template's arguments are stored in the job as plain JSON: strings,
  numbers, booleans, `nil`, lists, and maps with string keys. They reach the
  template exactly as they went in, so callers project the few values the
  email needs (a date as an ISO 8601 string) rather than passing a struct or
  a provider object, which would not survive a rename while the job waits
  and would put whatever else it holds into the job table.
  """

  use Oban.Worker, queue: :emails, max_attempts: 10, priority: 1

  require Logger

  alias Tymeslot.Auth
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.ExpectedJobOutcome
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.TransactionalEmailDelivery

  @behaviour ExpectedJobOutcome

  @not_configured "template not configured"
  @not_allowed "template not allowed"
  @user_gone "user not found"

  @payment_templates %{
    refund_processed_template: [:refund_processed_email],
    trial_ending_reminder_template: [:trial_ending_reminder_email],
    dispute_alert_template: [
      :dispute_created_alert,
      :dispute_lost_alert,
      :dispute_won_notification
    ]
  }

  @type recipient :: {:user, pos_integer()} | {:address, String.t()}

  @impl ExpectedJobOutcome
  def expected_outcome?(reason),
    do:
      reason in [@not_configured, @user_gone] or
        TransactionalEmailDelivery.recipient_rejected?(reason)

  @doc """
  Enqueues the email `template_key`'s module builds with `template_fun`,
  called with the recipient (the user, or the address) followed by
  `template_args`, which must be plain JSON (see the moduledoc). Does
  nothing for a template the deployment has not configured (a self-hosted
  install has none of them); a pair that is not allowed, or arguments that
  are not plain JSON, return an error.
  """
  @spec enqueue(atom(), atom(), recipient(), list()) :: :ok | {:error, term()}
  def enqueue(template_key, template_fun, recipient, template_args)
      when is_atom(template_key) and is_atom(template_fun) and is_list(template_args) do
    with {:ok, allowed} <- allowed_templates() do
      cond do
        template_fun not in Map.get(allowed, template_key, []) ->
          {:error, {:template_not_allowed, template_key, template_fun}}

        not json?(template_args) ->
          {:error, :template_args_not_json}

        configured_template(template_key) ->
          insert(template_key, template_fun, recipient, template_args)

        true ->
          Logger.debug("Email template not configured, nothing sent", template: template_key)
          :ok
      end
    end
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    %{"template_key" => key, "template_fun" => fun, "recipient" => recipient} = args

    with {:ok, template_key, template_fun} <- allowed_pair(key, fun),
         {:ok, template} <- fetch_template(template_key),
         {:ok, first_arg} <- resolve_recipient(recipient) do
      email_args = [first_arg | args["template_args"]]

      case deliver(job, template, template_key, template_fun, email_args) do
        {:error, reason} = error ->
          if final_attempt?(job), do: alert_exhausted(job, template_key, template_fun, reason)
          error

        result ->
          result
      end
    end
  end

  # A raise (a template bug) on the final attempt loses the email as surely
  # as an error does, so it alerts too, then re-raises for Oban to record.
  defp deliver(job, template, template_key, template_fun, email_args) do
    DeliveryClaims.once(job, "email", fn ->
      template
      |> apply(template_fun, email_args)
      |> TransactionalEmailDelivery.deliver(job, "Configured email delivery failed",
        template: template_key
      )
    end)
  rescue
    exception ->
      if final_attempt?(job), do: alert_exhausted(job, template_key, template_fun, exception)
      reraise exception, __STACKTRACE__
  end

  defp final_attempt?(job), do: job.attempt >= job.max_attempts

  # The email is lost for good once Oban stops retrying, and a caller that
  # recorded it as sent will not queue it again, so an operator has to act
  # on it by hand.
  defp alert_exhausted(job, template_key, template_fun, reason) do
    AdminAlerts.report(:configured_email_exhausted,
      summary: "Configured email not sent after its final attempt",
      reason: reason,
      context: %{template: "#{template_key}.#{template_fun}", job_id: job.id}
    )
  end

  defp insert(template_key, template_fun, recipient, template_args) do
    job =
      new(%{
        "template_key" => Atom.to_string(template_key),
        "template_fun" => Atom.to_string(template_fun),
        "recipient" => encode_recipient(recipient),
        "template_args" => template_args
      })

    case Oban.insert(job) do
      {:ok, _job} -> :ok
      {:error, _reason} = error -> error
    end
  end

  # The deployment's extra templates must be `%{key => [function, ...]}` of
  # atoms, and must not name a payment template's key: merged over it, the
  # entry would be silently dropped or would widen what that key may run.
  defp allowed_templates do
    extra = Application.get_env(:tymeslot, :extra_configured_email_templates, %{})

    cond do
      not valid_extra?(extra) ->
        misconfigured(:extra_configured_email_templates_malformed)

      key = Enum.find(Map.keys(extra), &Map.has_key?(@payment_templates, &1)) ->
        misconfigured({:extra_configured_email_template_is_built_in, key})

      true ->
        {:ok, Map.merge(extra, @payment_templates)}
    end
  end

  defp valid_extra?(extra) when is_map(extra) do
    Enum.all?(extra, fn {key, funs} ->
      is_atom(key) and is_list(funs) and Enum.all?(funs, &is_atom/1)
    end)
  end

  defp valid_extra?(_extra), do: false

  defp misconfigured(reason) do
    Logger.error("Configured email templates are misconfigured", reason: LogFormat.reason(reason))
    {:error, reason}
  end

  # Matched as strings, so a job row naming an unknown atom is discarded
  # rather than creating one or raising.
  defp allowed_pair(key, fun) do
    with {:ok, allowed} <- allowed_templates(),
         {:ok, template_key} <- find_named(Map.keys(allowed), key),
         {:ok, template_fun} <- find_named(Map.fetch!(allowed, template_key), fun) do
      {:ok, template_key, template_fun}
    else
      {:error, _misconfigured} ->
        {:discard, @not_allowed}

      :error ->
        Logger.error("Configured email job names a template that is not allowed",
          template: key,
          template_fun: fun
        )

        {:discard, @not_allowed}
    end
  end

  defp find_named(atoms, name) do
    case Enum.find(atoms, &(Atom.to_string(&1) == name)) do
      nil -> :error
      atom -> {:ok, atom}
    end
  end

  defp json?(value) when is_binary(value), do: json_string?(value)

  defp json?(value) when is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp json?(list) when is_list(list), do: Enum.all?(list, &json?/1)

  defp json?(map) when is_map(map) and not is_struct(map),
    do:
      Enum.all?(map, fn {key, value} -> is_binary(key) and json_string?(key) and json?(value) end)

  defp json?(_other), do: false

  # PostgreSQL's jsonb refuses invalid UTF-8 and the NUL character, which
  # would otherwise raise at insert, in the webhook that enqueued.
  defp json_string?(string), do: String.valid?(string) and not String.contains?(string, "\u0000")

  defp configured_template(key) do
    template = Application.get_env(:tymeslot, key)
    if template && Code.ensure_loaded?(template), do: template
  end

  defp fetch_template(key) do
    case configured_template(key) do
      nil -> {:discard, @not_configured}
      template -> {:ok, template}
    end
  end

  # Every template reached from here greets a user by name, and
  # `Profiles.user_display_name/1` raises rather than guessing when the
  # profile is unloaded, so the user comes with it.
  defp resolve_recipient(%{"user_id" => user_id}) do
    case Auth.get_user_with_profile(user_id) do
      {:ok, user} -> {:ok, user}
      {:error, :not_found} -> {:discard, @user_gone}
    end
  end

  defp resolve_recipient(%{"address" => address}), do: {:ok, address}

  defp encode_recipient({:user, user_id}), do: %{"user_id" => user_id}
  defp encode_recipient({:address, address}), do: %{"address" => address}
end
