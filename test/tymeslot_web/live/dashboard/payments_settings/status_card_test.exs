defmodule TymeslotWeb.Dashboard.PaymentsSettings.StatusCardTest do
  use ExUnit.Case, async: true

  @moduletag :payments
  @moduletag :components

  import Phoenix.LiveViewTest

  alias TymeslotWeb.Dashboard.PaymentsSettings.StatusCard

  defp render_card(account) do
    render_component(&StatusCard.status_card/1, account: account)
  end

  describe "status_card/1 state machine" do
    test "deleted account renders the disconnected state" do
      html = render_card(%{deleted_at: DateTime.utc_now(), default_currency: "eur"})

      assert html =~ "Disconnected"
      assert html =~ "Reconnect to accept payments again."
      refute html =~ "Connected and ready"
    end

    test "disabled_reason on a submitted account renders the restricted (error) state with the reason" do
      html =
        render_card(%{
          deleted_at: nil,
          disabled_reason: "rejected.fraud",
          details_submitted: true,
          default_currency: "eur"
        })

      assert html =~ "Restricted"
      assert html =~ "Reason: rejected.fraud"
    end

    test "disabled_reason on an unsubmitted account stays incomplete, not restricted" do
      # A brand-new account Stripe stamps with `requirements.past_due` before the
      # host finishes onboarding must read as :incomplete, not :restricted.
      html =
        render_card(%{
          deleted_at: nil,
          disabled_reason: "requirements.past_due",
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: false,
          default_currency: "eur"
        })

      assert html =~ "Finish connecting Stripe"
      assert html =~ "Continue onboarding"
      refute html =~ "Restricted"
      refute html =~ "Reason: requirements.past_due"
    end

    test "charges and payouts enabled renders the connected (success) state" do
      html =
        render_card(%{
          deleted_at: nil,
          disabled_reason: nil,
          charges_enabled: true,
          payouts_enabled: true,
          details_submitted: true,
          default_currency: "eur"
        })

      assert html =~ "Connected and ready"
      assert html =~ "Charges and payouts are enabled."
      # A fully-onboarded account never shows the resume button.
      refute html =~ "Continue onboarding"
    end

    test "details submitted but charges disabled renders the pending-review (warning) state" do
      html =
        render_card(%{
          deleted_at: nil,
          disabled_reason: nil,
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: true,
          default_currency: "eur"
        })

      assert html =~ "Pending Stripe review"
      assert html =~ "Stripe is reviewing your account."
      # Nothing for the host to do while Stripe reviews — no resume button.
      refute html =~ "Continue onboarding"
    end

    test "incomplete account (no details submitted) prompts to finish onboarding with a button" do
      html =
        render_card(%{
          deleted_at: nil,
          disabled_reason: nil,
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: false,
          default_currency: "eur"
        })

      # Distinct from pending-review: nothing has been submitted to Stripe yet.
      assert html =~ "Finish connecting Stripe"
      refute html =~ "Pending Stripe review"
      # The apostrophe is HTML-escaped in the rendered output.
      assert html =~ "haven&#39;t finished onboarding yet."
      # The host can resume onboarding directly from the banner.
      assert html =~ "Continue onboarding"
      assert html =~ ~s(action="/dashboard/payments/connect")
      assert html =~ ~s(method="post")
    end
  end

  describe "message" do
    # Several sentences long, so it sits in the card's notice, which wraps,
    # rather than the one-line summary, which truncates from sm up.
    test "is the card's notice, not its summary" do
      doc =
        %{
          deleted_at: nil,
          disabled_reason: nil,
          charges_enabled: false,
          payouts_enabled: false,
          details_submitted: true,
          default_currency: "eur"
        }
        |> render_card()
        |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("[data-part='notice']") |> LazyHTML.text() =~
               "Stripe is reviewing your account."

      assert doc |> LazyHTML.query("[data-part='summary']") |> Enum.count() == 0
    end

    test "is marked as a fault only for a restricted account" do
      doc =
        %{
          deleted_at: nil,
          disabled_reason: "rejected.fraud",
          details_submitted: true,
          default_currency: "eur"
        }
        |> render_card()
        |> LazyHTML.from_fragment()

      assert doc |> LazyHTML.query("[data-part='notice'][data-tone='danger']") |> Enum.count() ==
               1
    end
  end

  describe "needs_onboarding?/1" do
    test "true only while onboarding is incomplete" do
      incomplete = %{deleted_at: nil, disabled_reason: nil, details_submitted: false}

      # Past-due before submission is still onboarding, so the operational
      # dashboard must stay hidden.
      incomplete_past_due = %{
        deleted_at: nil,
        disabled_reason: "requirements.past_due",
        details_submitted: false
      }

      submitted = %{deleted_at: nil, disabled_reason: nil, details_submitted: true}

      ready = %{
        deleted_at: nil,
        disabled_reason: nil,
        charges_enabled: true,
        payouts_enabled: true,
        details_submitted: true
      }

      assert StatusCard.needs_onboarding?(incomplete)
      assert StatusCard.needs_onboarding?(incomplete_past_due)
      refute StatusCard.needs_onboarding?(submitted)
      refute StatusCard.needs_onboarding?(ready)
    end
  end
end
