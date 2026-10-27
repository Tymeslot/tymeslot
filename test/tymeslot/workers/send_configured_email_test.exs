defmodule Tymeslot.Workers.SendConfiguredEmailTest do
  @moduledoc """
  An email a payment webhook enqueues waits out an open mail circuit (the
  job snoozes, spending no attempt) and goes out once it closes, instead of
  being dropped as it was when the webhook sent it inline.
  """

  # async: false: the template, the mailer adapter and the email circuit
  # breaker are global.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import ExUnit.CaptureLog
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.ConfigTestHelpers

  @moduletag :payments
  @moduletag :emails

  alias Swoosh.Email
  alias Tymeslot.Emails.Delivery
  alias Tymeslot.Emails.EmailService
  alias Tymeslot.Infrastructure.CircuitBreaker
  alias Tymeslot.Infrastructure.CircuitBreakerSupervisor
  alias Tymeslot.Test.FailingMailerAdapter
  alias Tymeslot.Workers.DeliveryClaims
  alias Tymeslot.Workers.SendConfiguredEmail

  defmodule Template do
    @moduledoc false
    @spec notice(term(), map()) :: Email.t()
    def notice(%{email: address}, %{"amount" => amount}), do: notice_email(address, amount)

    def notice(address, %{"amount" => amount}) when is_binary(address),
      do: notice_email(address, amount)

    # Raises until the test lets it build, as a template bug fixed by a
    # deploy would.
    @spec flaky(term(), map()) :: Email.t()
    def flaky(address, data) do
      if Application.get_env(:tymeslot, :test_configured_notice_raises, true),
        do: raise("template failed"),
        else: notice(address, data)
    end

    defp notice_email(address, amount) do
      Email.new(
        to: address,
        from: "noreply@example.com",
        subject: "Notice #{amount}",
        text_body: "Notice.",
        html_body: "<p>Notice.</p>"
      )
    end
  end

  setup do
    setup_config(:tymeslot, :test_configured_notice_template, Template)

    setup_config(:tymeslot, :extra_configured_email_templates, %{
      test_configured_notice_template: [:notice, :flaky]
    })

    Application.put_env(:swoosh, :shared_test_process, self())
    breaker = CircuitBreakerSupervisor.email_breaker_name()
    CircuitBreaker.reset(breaker)

    on_exit(fn ->
      Application.delete_env(:swoosh, :shared_test_process)
      CircuitBreaker.reset(breaker)
    end)

    %{breaker: breaker}
  end

  test "waits out an open mail circuit, then sends the email once", %{breaker: breaker} do
    user = insert(:user)
    insert(:profile, user: user)

    assert :ok =
             SendConfiguredEmail.enqueue(
               :test_configured_notice_template,
               :notice,
               {:user, user.id},
               [%{"amount" => 42}]
             )

    [job] = all_enqueued(worker: SendConfiguredEmail)
    open_breaker(breaker)

    assert {:snooze, _seconds} = quietly(fn -> run_attempt(job) end)
    refute_received {:email, _sent}

    CircuitBreaker.reset(breaker)
    assert :ok = run_attempt(job)
    assert_received {:email, %{subject: "Notice 42"}}

    # Claimed once sent: a rescued run sends nothing more.
    assert :ok = run_attempt(job)
    refute_received {:email, _again}
  end

  test "sends to an address, as the dispute alerts do" do
    :ok =
      SendConfiguredEmail.enqueue(
        :test_configured_notice_template,
        :notice,
        {:address, "ops@example.com"},
        [%{"amount" => 7}]
      )

    assert %{success: 1} = Oban.drain_queue(queue: :emails)
    assert_received {:email, %{subject: "Notice 7", to: [{"", "ops@example.com"}]}}
  end

  test "EmailService.enqueue_configured/4 is the public way in, and sends the same email" do
    :ok =
      EmailService.enqueue_configured(
        :test_configured_notice_template,
        :notice,
        {:address, "ops@example.com"},
        [%{"amount" => 9}]
      )

    assert %{success: 1} = Oban.drain_queue(queue: :emails)
    assert_received {:email, %{subject: "Notice 9", to: [{"", "ops@example.com"}]}}
  end

  test "an allowed template the deployment has not configured enqueues nothing" do
    setup_config(:tymeslot, :test_configured_notice_template, nil)

    assert :ok =
             SendConfiguredEmail.enqueue(
               :test_configured_notice_template,
               :notice,
               {:user, 1},
               []
             )

    assert all_enqueued(worker: SendConfiguredEmail) == []
  end

  test "a template or function that is not allowed is refused at enqueue" do
    assert {:error, {:template_not_allowed, :no_such_template, :notice}} =
             SendConfiguredEmail.enqueue(:no_such_template, :notice, {:user, 1}, [])

    assert {:error, {:template_not_allowed, :test_configured_notice_template, :halt}} =
             SendConfiguredEmail.enqueue(:test_configured_notice_template, :halt, {:user, 1}, [])

    assert all_enqueued(worker: SendConfiguredEmail) == []
  end

  test "a job naming a template or function that is not allowed is discarded" do
    for {key, fun} <- [
          {"test_configured_notice_template", "halt"},
          {"no_such_template", "notice"}
        ] do
      job = job_for(%{"template_key" => key, "template_fun" => fun})

      assert {:discard, "template not allowed"} =
               quietly(fn -> SendConfiguredEmail.perform(job) end)
    end

    refute_received {:email, _sent}
  end

  test "arguments that are not plain JSON are refused at enqueue" do
    for args <- [
          [~D[2026-01-01]],
          [%{amount: 1}],
          [%{"user" => %Email{}}],
          [:stage],
          [<<0xFF, 0xFE>>],
          ["nul \u0000 byte"],
          [%{<<0xFF>> => 1}]
        ] do
      assert {:error, :template_args_not_json} =
               SendConfiguredEmail.enqueue(
                 :test_configured_notice_template,
                 :notice,
                 {:address, "ops@example.com"},
                 args
               )
    end

    assert all_enqueued(worker: SendConfiguredEmail) == []
  end

  test "a malformed extra template entry is a clean error, at enqueue and in the job" do
    for extra <- [%{test_configured_notice_template: :notice}, [notice: [:notice]]] do
      setup_config(:tymeslot, :extra_configured_email_templates, extra)

      assert {:error, :extra_configured_email_templates_malformed} =
               quietly(fn ->
                 SendConfiguredEmail.enqueue(
                   :test_configured_notice_template,
                   :notice,
                   {:address, "ops@example.com"},
                   []
                 )
               end)

      job =
        job_for(%{
          "template_key" => "test_configured_notice_template",
          "template_fun" => "notice"
        })

      assert {:discard, "template not allowed"} =
               quietly(fn -> SendConfiguredEmail.perform(job) end)
    end

    assert all_enqueued(worker: SendConfiguredEmail) == []
  end

  test "an extra entry naming a built-in template key is refused, not merged" do
    setup_config(:tymeslot, :extra_configured_email_templates, %{
      refund_processed_template: [:refund_processed_email, :halt]
    })

    assert {:error, {:extra_configured_email_template_is_built_in, :refund_processed_template}} =
             quietly(fn ->
               SendConfiguredEmail.enqueue(:refund_processed_template, :halt, {:user, 1}, [])
             end)
  end

  test "a user deleted before the job runs discards it" do
    user = insert(:user)

    :ok =
      SendConfiguredEmail.enqueue(:test_configured_notice_template, :notice, {:user, user.id}, [
        %{"amount" => 1}
      ])

    [job] = all_enqueued(worker: SendConfiguredEmail)
    Repo.delete!(user)

    assert {:discard, "user not found"} = SendConfiguredEmail.perform(job)
    refute_received {:email, _sent}
  end

  test "a permanently rejected address discards the job and alerts the operator" do
    capture_admin_alerts()
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)

    setup_config(
      :tymeslot,
      :test_delivery_error,
      {422, %{"ErrorCode" => 406, "Message" => "inactive recipient"}}
    )

    :ok =
      SendConfiguredEmail.enqueue(
        :test_configured_notice_template,
        :notice,
        {:address, "gone@example.com"},
        [%{"amount" => 3}]
      )

    [job] = all_enqueued(worker: SendConfiguredEmail)

    assert {:discard, "Recipient permanently undeliverable"} =
             quietly(fn -> SendConfiguredEmail.perform(job) end)

    assert_receive {:send_alert, :recipient_email_rejected, payload}
    assert payload.template == :test_configured_notice_template
  end

  test "a template that raises releases the claim, so the retry sends the email" do
    :ok =
      SendConfiguredEmail.enqueue(
        :test_configured_notice_template,
        :flaky,
        {:address, "ops@example.com"},
        [%{"amount" => 9}]
      )

    [job] = all_enqueued(worker: SendConfiguredEmail)

    assert_raise RuntimeError, "template failed", fn -> SendConfiguredEmail.perform(job) end
    refute DeliveryClaims.claimed?(job.id, "email")
    refute_received {:email, _sent}

    setup_config(:tymeslot, :test_configured_notice_raises, false)
    assert :ok = run_attempt(job)
    assert_received {:email, %{subject: "Notice 9"}}
  end

  defp open_breaker(breaker) do
    adapter = Application.get_env(:tymeslot, Tymeslot.Mailer)
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
    threshold = CircuitBreaker.status(breaker).config.failure_threshold

    quietly(fn ->
      for _attempt <- 1..threshold do
        Delivery.deliver(Email.new(to: "x@example.com", subject: "s", text_body: "t"))
      end
    end)

    Application.put_env(:tymeslot, Tymeslot.Mailer, adapter)
    :sys.get_state(breaker)
    assert CircuitBreaker.status(breaker).status == :open
  end

  test "a send that fails its final attempt alerts the operator; earlier failures do not" do
    capture_admin_alerts()
    setup_config(:tymeslot, Tymeslot.Mailer, adapter: FailingMailerAdapter)
    setup_config(:tymeslot, :test_delivery_error, :econnrefused)

    :ok =
      SendConfiguredEmail.enqueue(
        :test_configured_notice_template,
        :notice,
        {:address, "ops@example.com"},
        [%{"amount" => 5}]
      )

    [job] = all_enqueued(worker: SendConfiguredEmail)

    assert {:error, _reason} = quietly(fn -> SendConfiguredEmail.perform(job) end)
    refute_received {:send_alert, :configured_email_exhausted, _payload}

    final = %{job | attempt: job.max_attempts}
    assert {:error, _reason} = quietly(fn -> SendConfiguredEmail.perform(final) end)

    assert_receive {:send_alert, :configured_email_exhausted, payload}
    assert payload.template == "test_configured_notice_template.notice"
    assert payload.job_id == job.id
  end

  test "a template that raises on the final attempt alerts the operator" do
    capture_admin_alerts()

    :ok =
      SendConfiguredEmail.enqueue(
        :test_configured_notice_template,
        :flaky,
        {:address, "ops@example.com"},
        [%{"amount" => 5}]
      )

    [job] = all_enqueued(worker: SendConfiguredEmail)

    assert_raise RuntimeError, fn ->
      SendConfiguredEmail.perform(%{job | attempt: job.max_attempts})
    end

    assert_receive {:send_alert, :configured_email_exhausted,
                    %{template: "test_configured_notice_template.flaky"}}
  end

  defp job_for(args) do
    %Oban.Job{
      attempt: 1,
      meta: %{},
      args:
        Map.merge(
          %{
            "recipient" => %{"address" => "ops@example.com"},
            "template_args" => [%{"amount" => 1}]
          },
          args
        )
    }
  end

  defp run_attempt(job), do: SendConfiguredEmail.perform(%{job | attempt: job.attempt + 1})

  defp quietly(fun) do
    capture_log(fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    result
  end
end
