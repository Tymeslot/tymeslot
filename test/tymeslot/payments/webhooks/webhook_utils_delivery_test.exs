defmodule Tymeslot.Payments.Webhooks.WebhookUtilsDeliveryTest do
  @moduledoc """
  A user email a payment webhook sends goes out from a job through
  `Tymeslot.Emails.Delivery`, like every other email: headers cleaned,
  breaker and send deadline applied, and an open breaker waited out rather
  than the email dropped.
  """

  # async: false: the template is global configuration, and so is the Swoosh
  # test process.
  use Tymeslot.DataCase, async: false

  import Tymeslot.ConfigTestHelpers

  @moduletag :payments

  alias Swoosh.Email
  alias Tymeslot.Payments.Webhooks.WebhookUtils

  defmodule Template do
    @moduledoc false
    @spec notice(map()) :: Email.t()
    def notice(user) do
      Email.new(
        to: {"Payer\r\nBcc: x@example.com", user.email},
        from: {"Tymeslot", "noreply@example.com"},
        subject: "Your refund\r\nX-Injected: yes",
        text_body: "Refunded.",
        html_body: "<p>Refunded.</p>"
      )
    end
  end

  setup do
    setup_config(:tymeslot, :test_payment_notice_template, Template)

    setup_config(:tymeslot, :extra_configured_email_templates, %{
      test_payment_notice_template: [:notice]
    })

    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
  end

  test "sends through Delivery, which cleans the header values" do
    user = insert(:user)
    insert(:profile, user: user)

    assert :ok =
             WebhookUtils.deliver_user_email(
               user.id,
               :test_payment_notice_template,
               :notice,
               [],
               []
             )

    # From a job, which the mail outage that would refuse a send waits out.
    assert %{success: 1} = Oban.drain_queue(queue: :emails)

    assert_received {:email, sent}
    assert sent.subject == "Your refund X-Injected: yes"
    assert sent.to == [{"Payer Bcc: x@example.com", user.email}]
  end
end
