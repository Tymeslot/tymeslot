defmodule Tymeslot.MeetingPayments.DataRetentionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Tymeslot.MeetingPayments.ConnectAccountQueries
  alias Tymeslot.MeetingPayments.DataRetention

  describe "anonymise_host/1" do
    test "scrubs attendee PII, retains host PII, soft-deletes connect, touches both tables" do
      user = insert(:user, email: "host@example.com")
      insert(:connect_account, user: user, status: "active")

      bp =
        insert(:booking_payment,
          host_user_id: user.id,
          host_email: "host@example.com",
          host_name: "Host Person",
          attendee_email: "alice@example.com",
          attendee_name: "Alice",
          meeting_type_name: "Consult"
        )

      pt =
        insert(:payment_transaction,
          user: user,
          host_email: "host@example.com",
          host_name: "Host Person"
        )

      assert :ok = DataRetention.anonymise_host(user.id)

      bp = Repo.reload(bp)
      # host snapshot retained
      assert bp.host_email == "host@example.com"
      assert bp.host_name == "Host Person"
      assert bp.host_user_id == user.id
      # attendee PII scrubbed
      assert bp.attendee_email =~ "@deleted.local"
      assert bp.attendee_name == "Deleted Attendee"
      assert bp.meeting_type_name == "[deleted]"
      assert bp.host_deleted_at != nil

      pt = Repo.reload(pt)
      assert pt.user_id == nil
      # host snapshot retained on payment_transactions
      assert pt.host_email == "host@example.com"
      assert pt.host_name == "Host Person"
      assert pt.host_deleted_at != nil

      # connect_account is soft-deleted and excluded from the live lookup
      refute ConnectAccountQueries.live_for_user(user.id)
    end

    test "is idempotent — re-running does not re-stamp already anonymised rows" do
      user = insert(:user)
      insert(:connect_account, user: user)

      bp = insert(:booking_payment, host_user_id: user.id)
      pt = insert(:payment_transaction, user: user)

      assert :ok = DataRetention.anonymise_host(user.id)

      first_bp = Repo.reload(bp)
      first_pt = Repo.reload(pt)
      first_stamp_bp = first_bp.host_deleted_at
      first_stamp_pt = first_pt.host_deleted_at

      assert first_stamp_bp != nil
      assert first_stamp_pt != nil

      # Running again must not touch already-anonymised rows.
      assert :ok = DataRetention.anonymise_host(user.id)

      assert Repo.reload(bp).host_deleted_at == first_stamp_bp
      assert Repo.reload(pt).host_deleted_at == first_stamp_pt
    end

    test "is a no-op when the user has no payment-related rows" do
      user = insert(:user)
      assert :ok = DataRetention.anonymise_host(user.id)
    end
  end
end
