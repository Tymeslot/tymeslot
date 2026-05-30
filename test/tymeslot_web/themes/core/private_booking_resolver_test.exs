defmodule TymeslotWeb.Themes.Core.PrivateBookingResolverTest do
  @moduledoc """
  Tests for the PrivateBookingResolver that decodes private booking tokens
  and assigns organizer context onto the socket.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :meeting_types

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.MeetingTypes.PrivateLinkToken
  alias TymeslotWeb.Themes.Core.PrivateBookingResolver

  # Minimal socket that satisfies Phoenix.Component.assign/3 validation.
  # assign/3 accepts any %Phoenix.LiveView.Socket{} struct.
  defp fake_socket do
    %Phoenix.LiveView.Socket{}
  end

  describe "resolve/2 with a valid token" do
    test "assigns organizer_profile, organizer_user_id, and meeting_types" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      mt = insert(:meeting_type, user: user, is_active: true)

      token = PrivateLinkToken.sign(user.id, mt.id)

      assert {:ok, socket} = PrivateBookingResolver.resolve(token, fake_socket())
      assert socket.assigns.organizer_user_id == user.id
      assert [resolved_mt] = socket.assigns.meeting_types
      assert resolved_mt.id == mt.id
    end

    test "meeting_types list contains exactly one entry" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      _other_mt = insert(:meeting_type, user: user, name: "Other Call", is_active: true)
      target_mt = insert(:meeting_type, user: user, name: "Target Call", is_active: true)

      token = PrivateLinkToken.sign(user.id, target_mt.id)

      assert {:ok, socket} = PrivateBookingResolver.resolve(token, fake_socket())
      assert length(socket.assigns.meeting_types) == 1
      assert hd(socket.assigns.meeting_types).id == target_mt.id
    end

    test "works for an inactive meeting type (private links bypass is_active)" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      mt = insert(:meeting_type, user: user, is_active: false)

      token = PrivateLinkToken.sign(user.id, mt.id)

      assert {:ok, socket} = PrivateBookingResolver.resolve(token, fake_socket())
      assert hd(socket.assigns.meeting_types).id == mt.id
    end

    test "assigns page_title containing the meeting type name" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      mt = insert(:meeting_type, user: user, name: "Coffee Chat")

      token = PrivateLinkToken.sign(user.id, mt.id)

      assert {:ok, socket} = PrivateBookingResolver.resolve(token, fake_socket())
      assert socket.assigns.page_title =~ "Coffee Chat"
    end
  end

  describe "resolve/2 with an expired token" do
    test "returns {:error, :expired}" do
      user = insert(:user)
      _profile = insert(:profile, user: user)
      mt = insert(:meeting_type, user: user)

      # Build a token that expired 1 second ago
      expired_token =
        Phoenix.Token.sign(
          TymeslotWeb.Endpoint,
          "private_booking_link_v1",
          {user.id, mt.id, System.os_time(:second) - 1}
        )

      assert {:error, :expired} = PrivateBookingResolver.resolve(expired_token, fake_socket())
    end
  end

  describe "resolve/2 with an invalid token" do
    test "returns {:error, :invalid} for a garbage string" do
      assert {:error, :invalid} = PrivateBookingResolver.resolve("garbage", fake_socket())
    end

    test "returns {:error, :invalid} when meeting type does not exist" do
      user = insert(:user)
      _profile = insert(:profile, user: user)

      token = PrivateLinkToken.sign(user.id, 999_999)

      assert {:error, :invalid} = PrivateBookingResolver.resolve(token, fake_socket())
    end

    test "returns {:error, :invalid} when user/profile does not exist" do
      token = PrivateLinkToken.sign(999_999, 1)

      assert {:error, :invalid} = PrivateBookingResolver.resolve(token, fake_socket())
    end

    test "returns {:error, :invalid} when meeting type belongs to a different user" do
      user_a = insert(:user)
      user_b = insert(:user)
      _profile_b = insert(:profile, user: user_b)
      mt_a = insert(:meeting_type, user: user_a)

      # Token claims user_b owns mt_a — should be rejected
      token = PrivateLinkToken.sign(user_b.id, mt_a.id)

      assert {:error, :invalid} = PrivateBookingResolver.resolve(token, fake_socket())
    end
  end
end
