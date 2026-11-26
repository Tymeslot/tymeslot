defmodule Tymeslot.Workers.SendBookingPaymentRefundedTest do
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :emails
  @moduletag :payments

  import Swoosh.TestAssertions
  import Tymeslot.ConfigTestHelpers, only: [with_config: 3]

  alias Ecto.UUID
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  # Swoosh's test adapter posts {:email, ...} to whichever process calls
  # Mailer.deliver/1, which is the CircuitBreaker GenServer — not the test
  # process. Pointing the adapter at this test collects the delivered emails
  # here instead, so the delivery branches can be told apart from the no-op
  # one. Safe because the module is `async: false`.
  setup do
    Application.put_env(:swoosh, :shared_test_process, self())
    on_exit(fn -> Application.delete_env(:swoosh, :shared_test_process) end)
    :ok
  end

  defp insert_payment(attrs \\ %{}) do
    defaults = %{
      attendee_email: "alice@example.com",
      attendee_name: "Alice",
      host_name: "Bob Host",
      meeting_type_name: "Discovery Call",
      amount_cents: 5000,
      refunded_amount_cents: 5000,
      currency: "eur",
      status: :refunded,
      stripe_account_id: "acct_TEST",
      paid_at: DateTime.utc_now(:second)
    }

    insert(:booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  describe "perform/1" do
    test "delivers a refund email for a fully-refunded booking" do
      payment = insert_payment()

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        assert email.to == [{"Alice", "alice@example.com"}]
        assert email.subject == "Refund Issued - €50.00"
        assert email.text_body =~ "€50.00"
      end)
    end

    test "delivers a partial refund email when amounts differ" do
      payment = insert_payment(%{refunded_amount_cents: 2000, status: :partially_refunded})

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        assert email.to == [{"Alice", "alice@example.com"}]
        assert email.subject == "Partial Refund Issued - €20.00"
        # The partial branch names the refunded amount against the original.
        assert email.text_body =~ "€20.00"
        assert email.text_body =~ "€50.00"
      end)
    end

    # The meeting's stored title is the host's calendar event, naming the
    # booker in the host's language; the booker reads the booking named after
    # the host, in theirs.
    test "names the booking after the host, in the booker's language" do
      meeting =
        insert(:meeting,
          title: "Discovery Call mit Alice",
          meeting_type: "Discovery Call",
          attendee_name: "Alice",
          attendee_locale: "it"
        )

      payment = insert_payment(%{meeting_id: meeting.id})

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        refute email.text_body =~ "con Alice"
        assert email.text_body =~ "Discovery Call con Bob Host"
      end)
    end

    # A group meeting's `attendee_locale` is its first booker's, so a later
    # seat's refund notice is written in that seat's booker's own language.
    test "writes a seat's refund in that seat's booker's language" do
      meeting =
        insert(:group_meeting, capacity: 3, meeting_type: "Workshop", attendee_locale: "en")

      _first = insert(:participant, meeting: meeting, locale: "en")
      second = insert(:participant, meeting: meeting, locale: "de")

      payment =
        insert_payment(%{
          meeting_id: meeting.id,
          participant_id: second.id,
          seat_payment: true
        })

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        assert email.subject == "Rückerstattung veranlasst – 50,00\u00A0€"
      end)
    end

    # A seat whose checkout was never confirmed has no participant; its hold
    # carries the booker's language.
    test "writes an unconfirmed seat's refund in its hold's language" do
      meeting = insert(:group_meeting, capacity: 3, attendee_locale: "en")
      hold = insert(:seat_hold, meeting: meeting, locale: "de")

      payment =
        insert_payment(%{meeting_id: meeting.id, seat_hold_id: hold.id, seat_payment: true})

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        assert email.subject == "Rückerstattung veranlasst – 50,00\u00A0€"
      end)
    end

    # With the booking gone (or never linked) there is no booker language to
    # read, so the notice is written in the booking pages' default, as every
    # other booking email is, rather than in English.
    test "writes in the booking pages' default language when the booking is gone" do
      with_config(:tymeslot, :booking_default_locale, "de")
      payment = insert_payment(%{meeting_id: nil})

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        assert email.subject == "Rückerstattung veranlasst – 50,00\u00A0€"
      end)
    end

    test "lets the booker reply to the host" do
      payment = insert_payment(%{host_email: "bob@example.com"})

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        assert email.to == [{"Alice", "alice@example.com"}]
        assert email.reply_to == {"Bob Host", "bob@example.com"}
      end)
    end

    test "discards when booking_payment is missing" do
      assert {:discard, "booking_payment not found"} =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => UUID.generate()
               })
    end

    test "no-ops when refunded_amount_cents is zero" do
      payment = insert_payment(%{refunded_amount_cents: 0, status: :paid})

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      refute_email_sent()
    end

    test "the refund email states only the refund made" do
      payment =
        insert_payment(%{
          amount_cents: 10_000,
          refunded_amount_cents: 10_000,
          disputed_lost_cents: 6_000,
          status: :disputed
        })

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        assert email.subject == "Partial Refund Issued - €40.00"

        assert email.text_body =~
                 "Hi Alice, €40.00 of your €100.00 payment has been refunded."

        assert email.html_body =~ "€40.00 of your €100.00 payment has been refunded."

        for body <- [email.text_body, email.html_body] do
          refute body =~ "€100.00 has been refunded"
          refute body =~ "refunded in full"
          refute body =~ "dispute"
        end
      end)
    end

    test "the refund email still goes out once a dispute over the same money is lost" do
      payment =
        insert_payment(%{
          amount_cents: 10_000,
          refunded_amount_cents: 10_000,
          stripe_refunded_cents: 10_000,
          disputed_lost_cents: 10_000,
          status: :refunded
        })

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      assert_email_sent(fn email ->
        assert email.to == [{"Alice", "alice@example.com"}]
        assert email.subject == "Refund Issued - €100.00"
      end)
    end

    test "no refund email when only a dispute took the money" do
      payment =
        insert_payment(%{
          refunded_amount_cents: 3_000,
          disputed_lost_cents: 3_000,
          status: :disputed
        })

      assert :ok =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })

      refute_email_sent()
    end

    test "discards when booking_payment_id is missing from args" do
      assert {:discard, "missing booking_payment_id"} =
               perform_job(SendBookingPaymentRefunded, %{})
    end

    test "discards when attendee_email has been anonymised to nil" do
      payment = insert_payment(%{attendee_email: nil})

      assert {:discard, "missing attendee_email"} =
               perform_job(SendBookingPaymentRefunded, %{
                 "booking_payment_id" => payment.id
               })
    end
  end

  describe "uniqueness" do
    test "second Oban.insert for the same booking_payment_id within 24 h is a conflict" do
      payment = insert_payment()
      args = %{"booking_payment_id" => payment.id}

      assert {:ok, %{conflict?: false}} = Oban.insert(SendBookingPaymentRefunded.new(args))
      assert {:ok, %{conflict?: true}} = Oban.insert(SendBookingPaymentRefunded.new(args))
    end
  end
end
