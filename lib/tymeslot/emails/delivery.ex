defmodule Tymeslot.Emails.Delivery do
  @moduledoc """
  Email delivery infrastructure — circuit breaker, retry logic, and validation.

  All `send_*` functions in `Tymeslot.Emails.EmailService` delegate to
  `deliver/1` here once they have built a `Swoosh.Email` struct.
  """

  require Logger

  alias Tymeslot.Emails.Shared.Sanitise
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Infrastructure.Tasks
  alias Tymeslot.Mailer

  # Postmark reports an API-level rejection as `{422, %{"ErrorCode" => code}}`.
  # 300 (invalid email address) and 406 (inactive recipient — a prior hard
  # bounce, spam complaint, or manual suppression) can never succeed on retry.
  # Server, auth, and configuration codes are deliberately excluded so genuine
  # operational problems still surface as retryable failures.
  @permanent_rejection_codes [300, 406]

  # The SMTP counterpart: RFC 3463 enhanced status codes that describe the
  # address itself (bad mailbox, bad domain, bad syntax, domain accepts no
  # mail, mailbox disabled). Reply codes alone cannot be used: a 550 or 553
  # equally means "relaying denied" or "sender not owned", which are
  # configuration problems every email hits.
  @smtp_permanent_rejection ~r/\b5\.1\.(1|2|3|10)\b|\b5\.2\.1\b/

  # gen_smtp waits a fixed 20 minutes for each reply once connected, and Oban
  # workers kill a job that outlives their own budget from the outside,
  # where neither the breaker nor the retry policy sees it. Bounding each send
  # here, inside the breaker, turns a hung relay into an ordinary timeout;
  # `EmailWorker` sizes its budget from this deadline. It must stay above
  # `Tymeslot.Mailer.SMTPAdapter`'s 15-second session deadline, which is what
  # reports a relay that hung before any message data was sent as retryable.
  @default_send_deadline_ms 20_000
  @ambiguous_policy {__MODULE__, :ambiguous_timeouts}
  @ambiguous_seen {__MODULE__, :ambiguous_timeout_seen}

  @doc """
  Delivers an email using the configured mailer, wrapped in a circuit breaker.

  Retries are delegated to Oban (a single retry authority) rather than retried
  here — re-sending the same message on a flaky transport is what produces
  duplicate emails. A timeout that may have come after the message was
  handed over is treated as delivered for the same reason (see
  `timeout_error?/1`). Display names and the subject are stripped of control
  characters before the adapter sees them.

  Returns `{:error, {:recipient_rejected, reason}}` when the provider rejects
  the address permanently; callers should give up rather than retry.

  `breaker:` names the circuit breaker to deliver through, the application's
  email breaker by default; tests pass their own so that no other delivery
  can change the counts they assert on.
  """
  @spec deliver(Swoosh.Email.t(), keyword()) :: {:ok, any()} | {:error, any()}
  def deliver(email, opts \\ []) do
    email = sanitise_headers(email)

    with :ok <- check_text_body(email) do
      Logger.debug("Delivering email via Mailer", recipient_domains: recipient_domains(email))

      CircuitBreaker.call(
        Keyword.get_lazy(opts, :breaker, &CircuitBreakerSupervisor.email_breaker_name/0),
        fn -> email |> deliver_within_deadline() |> handle_delivery_result(email) end,
        classify: &classify_outcome/1
      )
    end
  end

  @doc """
  Runs `fun` with `policy` for ambiguous timeouts in every `deliver/2` it
  makes, and returns `{result, ambiguous?}`: `fun`'s result, and whether a
  delivery in it hit an ambiguous timeout.

  `:retry_once` reports such a timeout as `{:error, {:ambiguous, reason}}`
  so the caller retries it, which only a caller that records the retry can
  bound; `:assume_delivered` reports it as `{:ok, :assumed_delivered}`, the
  default outside this function.

  `on_ambiguous:` is called once, at the first ambiguous timeout under
  `:retry_once`, before that delivery returns: the caller records the retry
  there, so the record stands even if something later in `fun` crashes.
  """
  @spec with_ambiguous_timeouts(:retry_once | :assume_delivered, (-> result), keyword()) ::
          {result, boolean()}
        when result: term()
  def with_ambiguous_timeouts(policy, fun, opts \\ [])
      when policy in [:retry_once, :assume_delivered] do
    Process.put(@ambiguous_policy, {policy, Keyword.get(opts, :on_ambiguous)})
    Process.delete(@ambiguous_seen)

    try do
      result = fun.()
      {result, Process.get(@ambiguous_seen, false)}
    after
      Process.delete(@ambiguous_policy)
      Process.delete(@ambiguous_seen)
    end
  end

  # `BreakerOutcome`'s default classifier only recognises a narrow set of
  # transport/HTTP error shapes; Tymeslot supports several mail adapters
  # (Postmark, SendGrid, Mailgun, AhaSend, SMTP) whose error reasons don't
  # share one shape (Postmark's is a bare `{status, body}`, not the
  # `{:http_error, status, body}` tuple the default classifier looks for).
  # `handle_delivery_error/2` already sorts every failure into permanent/timeout/transient
  # via `classify/1` before it gets here, so that triage is reused directly
  # instead of guessing again from the raw reason.
  defp classify_outcome({:error, {:recipient_rejected, _reason}}), do: :ignore
  defp classify_outcome({:error, _reason}), do: :failure
  # An ambiguous timeout is reported to the caller as `:assumed_delivered` or,
  # under `with_ambiguous_timeouts(:retry_once, _)`, as `{:error, {:ambiguous, _}}`
  # (see `handle_delivery_error/3` below), but either way it is evidence the
  # provider is unhealthy — a hung connection is the common shape of an
  # SMTP/API outage, so it must count as a breaker failure or the breaker
  # never opens for it.
  defp classify_outcome({:ok, :assumed_delivered}), do: :failure
  defp classify_outcome(_other), do: :success

  # The adapter runs in its own process so the deadline can stop it: the
  # socket belongs to that process and closes with it. Unlinked, so an
  # adapter crash comes back here as an exit to re-raise rather than killing
  # the caller before the breaker has seen it.
  defp deliver_within_deadline(email) do
    deadline_ms = send_deadline_ms()
    task = Tasks.async_nolink(Tymeslot.TaskSupervisor, fn -> Mailer.deliver(email) end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, {exception, stacktrace}} when is_exception(exception) ->
        reraise exception, stacktrace

      {:exit, reason} ->
        exit(reason)

      nil ->
        {:error, {:send_deadline_exceeded, deadline_ms}}
    end
  end

  @doc "The longest a single `deliver/1` call may take before it gives up."
  @spec send_deadline_ms() :: pos_integer()
  def send_deadline_ms do
    Application.get_env(:tymeslot, :email_send_deadline_ms, @default_send_deadline_ms)
  end

  # AhaSend answers 202 Accepted with a body its adapter cannot always parse,
  # which reaches here as an error: the provider has taken the message.
  defp handle_delivery_result({:error, {202, _body}}, email) do
    Logger.info("Email accepted by the provider", recipient_domains: recipient_domains(email))
    {:ok, :accepted}
  end

  defp handle_delivery_result({:ok, _receipt} = result, email) do
    Logger.info("Email delivered successfully", recipient_domains: recipient_domains(email))

    result
  end

  defp handle_delivery_result({:error, reason}, email), do: handle_delivery_error(email, reason)

  defp handle_delivery_error(email, reason),
    do: handle_delivery_error(classify(reason), email, reason)

  # The provider has permanently rejected the address. Reported to the caller
  # as an error, but `BreakerOutcome.classify/1` leaves the breaker untouched
  # for it: a handful of suppressed addresses must not open a breaker that
  # blocks *all* outbound mail.
  defp handle_delivery_error(:permanent, email, reason) do
    Logger.warning("Email permanently undeliverable — recipient rejected by the provider",
      recipient_domains: recipient_domains(email),
      reason: LogFormat.reason(reason)
    )

    {:error, {:recipient_rejected, reason}}
  end

  # A timeout after the message may have been handed over is ambiguous: the
  # provider has quite possibly accepted it, and only the client gave up
  # waiting. Retrying every such timeout duplicates mail; assuming every one
  # delivered loses mail behind a provider that never took it. A caller that
  # can bound the retry (an email job, which records that it already retried
  # once) asks for one retry through `with_ambiguous_timeouts/2`; everyone
  # else assumes delivery, as before.
  defp handle_delivery_error(:timeout, email, reason) do
    case Process.get(@ambiguous_policy) do
      {:retry_once, on_ambiguous} ->
        note_ambiguous(on_ambiguous)

        Logger.warning("Email delivery timed out and may have been sent; retrying it once",
          recipient_domains: recipient_domains(email),
          reason: LogFormat.reason(reason)
        )

        {:error, {:ambiguous, reason}}

      _assume_delivered ->
        Logger.warning("Email delivery timed out; assuming delivered to avoid duplicate sends",
          recipient_domains: recipient_domains(email),
          reason: LogFormat.reason(reason)
        )

        {:ok, :assumed_delivered}
    end
  end

  defp handle_delivery_error(:transient, email, reason) do
    Logger.error("Failed to deliver email",
      recipient_domains: recipient_domains(email),
      reason: LogFormat.reason(reason)
    )

    {:error, reason}
  end

  defp note_ambiguous(on_ambiguous) do
    unless Process.get(@ambiguous_seen, false) do
      Process.put(@ambiguous_seen, true)
      if is_function(on_ambiguous, 0), do: on_ambiguous.()
    end
  end

  defp classify(reason) do
    cond do
      permanent_rejection?(reason) -> :permanent
      timeout_error?(reason) -> :timeout
      true -> :transient
    end
  end

  @doc """
  The email circuit breaker's configuration, for a worker that delivers email
  through a breaker of its own and should trip on the same terms.
  """
  @spec email_breaker_config() :: map()
  defdelegate email_breaker_config, to: CircuitBreakerSupervisor

  @doc """
  How long the email circuit breaker stays open before it probes the
  provider again, so a worker that must outwait an open circuit can snooze
  for that long instead of repeating the number.
  """
  @spec email_breaker_recovery_seconds() :: pos_integer()
  defdelegate email_breaker_recovery_seconds, to: CircuitBreakerSupervisor

  @doc """
  True while the email circuit breaker would refuse a delivery made now (see
  `Tymeslot.Infrastructure.CircuitBreaker.refusing?/1`). Reads the state
  without changing it, so a caller can skip work that only makes sense if
  the email can go out.
  """
  @spec email_breaker_refusing?() :: boolean()
  def email_breaker_refusing?,
    do: CircuitBreaker.refusing?(CircuitBreakerSupervisor.email_breaker_name())

  @doc """
  Returns true when a delivery error reason is a permanent recipient rejection.

  A permanent rejection means the address itself is undeliverable — an invalid
  address, or one the provider has suppressed after a hard bounce or spam
  complaint. No number of retries can succeed, so callers should stop rather
  than back off.

  Accepts both the raw provider reason and the `{:recipient_rejected, reason}`
  tuple `deliver/1` returns, so it can be applied at either layer.
  """
  @spec permanent_rejection?(term()) :: boolean()
  def permanent_rejection?({422, %{"ErrorCode" => code}})
      when code in @permanent_rejection_codes,
      do: true

  def permanent_rejection?({:recipient_rejected, _reason}), do: true

  def permanent_rejection?({:send, {:permanent_failure, _host, message}}) when is_binary(message),
    do: message =~ @smtp_permanent_rejection

  def permanent_rejection?(_reason), do: false

  @doc """
  Returns true when a delivery error reason is a timeout that may have come
  after the message was handed over, so the email may have gone out.

  Each adapter's shape is matched explicitly:

    * our own send deadline (`{:send_deadline_exceeded, _}`) and a bare
      `:timeout`: the adapter was mid-send, ambiguous;
    * gen_smtp timing out after the session opened
      (`{:send, {:network_failure, _host, {:error, :timeout}}}`): ambiguous.
      A connection it lost there (`{:error, :closed}`) is not: gen_smtp
      reports it alike for MAIL FROM, RCPT TO and DATA, so it cannot say
      whether anything was sent, and a duplicate is preferred to a loss;
    * gen_smtp failing while opening the session (`{:retries_exceeded, _}`,
      `{:no_more_hosts, _}`): before any message data, so certainly not sent,
      and retryable. Treating it as delivered is how an unreachable relay
      once silently swallowed every email;
    * an API adapter's transport timeout (`%Finch.TransportError{}`, or
      `%Mint.TransportError{}` from an older client), and a gateway's 504:
      ambiguous. Finch wraps a connect timeout and a receive timeout in the
      same struct, with nothing saying which phase failed, so a connect
      timeout cannot be told apart and is treated as ambiguous too: under
      the bounded retry it gets one more attempt;
    * anything else, including other HTTP statuses and transport errors:
      not a timeout, so retryable.

  A reason that only mentions a timeout somewhere in its text is not one.
  """
  @spec timeout_error?(term()) :: boolean()
  def timeout_error?(:timeout), do: true
  def timeout_error?({:send_deadline_exceeded, _deadline_ms}), do: true

  def timeout_error?({:send, {:network_failure, _host, {:error, :timeout}}}), do: true

  def timeout_error?(%Finch.TransportError{reason: :timeout}), do: true
  def timeout_error?(%Mint.TransportError{reason: :timeout}), do: true
  def timeout_error?({504, _body}), do: true
  def timeout_error?(_reason), do: false

  @doc """
  `email` as `deliver/2` hands it to the adapter: every display name and the
  subject stripped of control characters, everything else (addresses,
  bodies, private data) as it was.

  Header values reach the adapter's header encoding as they are, so a CR or
  LF in a display name or subject (an attendee's name, a meeting title) is
  replaced here, once, rather than by each template remembering to.
  """
  @spec sanitise_headers(Swoosh.Email.t()) :: Swoosh.Email.t()
  def sanitise_headers(%Swoosh.Email{} = email) do
    %{
      email
      | subject: Sanitise.sanitize_for_header(email.subject),
        from: clean_address(email.from),
        reply_to: clean_address(email.reply_to),
        to: Enum.map(email.to, &clean_address/1),
        cc: Enum.map(email.cc, &clean_address/1),
        bcc: Enum.map(email.bcc, &clean_address/1)
    }
  end

  defp clean_address({name, address}) when is_binary(name),
    do: {Sanitise.sanitize_for_header(name), address}

  defp clean_address(address), do: address

  defp check_text_body(%Swoosh.Email{text_body: body, subject: subject}) when body in [nil, ""] do
    Logger.error("Refusing to deliver email without a plain-text body")

    {:error, {:missing_text_body, subject}}
  end

  defp check_text_body(%Swoosh.Email{}), do: :ok

  # Where a message went, without saying to whom: these lines are written for
  # every email, and the recipients are mostly invitees without an account.
  # The domain is enough to tell a provider-wide problem from one mailbox's.
  defp recipient_domains(%Swoosh.Email{to: to, cc: cc, bcc: bcc}) do
    (to ++ cc ++ bcc)
    |> Enum.map(&recipient_domain/1)
    |> Enum.uniq()
  end

  defp recipient_domain({_name, address}) when is_binary(address) do
    case String.split(address, "@") do
      [_local, domain] -> String.downcase(domain)
      _malformed -> "invalid"
    end
  end

  defp recipient_domain(_recipient), do: "invalid"
end
