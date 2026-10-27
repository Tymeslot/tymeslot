defmodule Tymeslot.Integrations.Shared.OAuth.PendingFlowTest do
  use Tymeslot.DataCase, async: true

  @moduletag :integrations

  import Tymeslot.Factory
  import Tymeslot.Test.ClockHelpers

  alias Ecto.Adapters.SQL.Sandbox
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlow
  alias Tymeslot.Integrations.Shared.OAuth.PendingFlowSchema
  alias Tymeslot.Repo

  defp s256(verifier), do: Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false)

  describe "start/2 and consume/3" do
    test "hand back the verifier whose S256 challenge the flow started with" do
      user = insert(:user)
      {:ok, %{nonce: nonce, code_challenge: challenge}} = PendingFlow.start(user.id, :outlook)

      assert {:ok, verifier} = PendingFlow.consume(nonce, user.id, :outlook)
      assert byte_size(verifier) >= 43
      assert s256(verifier) == challenge
    end

    test "store the verifier encrypted, never as given" do
      user = insert(:user)
      {:ok, %{nonce: nonce}} = PendingFlow.start(user.id, :zoom)

      stored = Repo.get_by!(PendingFlowSchema, nonce: nonce)
      {:ok, verifier} = PendingFlow.consume(nonce, user.id, :zoom)

      refute stored.code_verifier_encrypted =~ verifier
    end

    test "let a flow be consumed once" do
      user = insert(:user)
      {:ok, %{nonce: nonce}} = PendingFlow.start(user.id, :google)

      assert {:ok, _verifier} = PendingFlow.consume(nonce, user.id, :google)
      assert {:error, :flow_not_found} = PendingFlow.consume(nonce, user.id, :google)
    end

    test "let exactly one of two racing callbacks consume a flow" do
      user = insert(:user)
      {:ok, %{nonce: nonce}} = PendingFlow.start(user.id, :teams)
      test_pid = self()

      results =
        1..2
        |> Enum.map(fn _n ->
          Task.async(fn ->
            Sandbox.allow(Repo, test_pid, self())
            PendingFlow.consume(nonce, user.id, :teams)
          end)
        end)
        |> Enum.map(&Task.await/1)

      assert Enum.count(results, &match?({:ok, _verifier}, &1)) == 1
      assert {:error, :flow_not_found} in results
    end

    test "refuse a flow presented by another user or at another provider" do
      user = insert(:user)
      {:ok, %{nonce: nonce}} = PendingFlow.start(user.id, :google)

      assert {:error, :flow_not_found} = PendingFlow.consume(nonce, insert(:user).id, :google)
      assert {:error, :flow_not_found} = PendingFlow.consume(nonce, user.id, :google_meet)
      assert {:ok, _verifier} = PendingFlow.consume(nonce, user.id, :google)
    end

    test "refuse a state that names no flow" do
      assert {:error, :flow_not_found} = PendingFlow.consume(nil, insert(:user).id, :google)
    end

    test "refuse a flow past its hour" do
      user = insert(:user)
      freeze_clock(~U[2026-10-07 12:00:00Z])
      {:ok, %{nonce: nonce}} = PendingFlow.start(user.id, :outlook)

      freeze_clock(~U[2026-10-07 13:00:00Z])

      assert {:error, :flow_not_found} = PendingFlow.consume(nonce, user.id, :outlook)
    end
  end

  describe "prune_expired/0" do
    test "deletes expired flows and keeps live ones" do
      user = insert(:user)
      freeze_clock(~U[2026-10-07 12:00:00Z])
      {:ok, %{nonce: expired}} = PendingFlow.start(user.id, :outlook)
      freeze_clock(~U[2026-10-07 12:30:00Z])
      {:ok, %{nonce: live}} = PendingFlow.start(user.id, :outlook)

      freeze_clock(~U[2026-10-07 13:15:00Z])

      assert {1, nil} = PendingFlow.prune_expired()
      assert Repo.get_by(PendingFlowSchema, nonce: expired) == nil
      assert Repo.get_by(PendingFlowSchema, nonce: live)
    end
  end
end
