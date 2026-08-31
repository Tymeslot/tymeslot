defmodule TymeslotWeb.Helpers.UploadHandlerTest do
  use TymeslotWeb.ConnCase, async: true

  @moduletag :utils

  alias Phoenix.LiveView.Socket
  alias Phoenix.LiveView.UploadEntry
  alias TymeslotWeb.Helpers.UploadHandler

  defp socket_with_entries(entries) do
    %Socket{assigns: %{uploads: %{avatar: %{entries: entries}}, __changed__: %{}}}
  end

  defp entry(ref, opts) do
    %UploadEntry{
      ref: ref,
      upload_config: :avatar,
      valid?: Keyword.get(opts, :valid?, true),
      done?: Keyword.get(opts, :done?, false)
    }
  end

  describe "settle_upload/2" do
    test "reports :settled once every entry has finished" do
      socket = socket_with_entries([entry("a", done?: true), entry("b", done?: true)])

      assert {_socket, :settled} = UploadHandler.settle_upload(socket, :avatar)
    end

    test "reports :in_progress while a sibling entry is still uploading" do
      # The shape that crashed the onboarding LiveView: the progress callback
      # runs for "a", which is done, while "b" is still in flight. Consuming
      # here raises ArgumentError.
      socket = socket_with_entries([entry("a", done?: true), entry("b", done?: false)])

      assert {_socket, :in_progress} = UploadHandler.settle_upload(socket, :avatar)
    end

    test "reports :settled when the upload key is not configured on the socket" do
      assert {_socket, :settled} =
               UploadHandler.settle_upload(%Socket{assigns: %{__changed__: %{}}}, :avatar)
    end
  end

  describe "upload_entries/2" do
    test "returns the configured entries" do
      socket = socket_with_entries([entry("a", done?: true)])

      assert [%UploadEntry{ref: "a"}] = UploadHandler.upload_entries(socket, :avatar)
    end

    test "returns [] when no upload is configured for the key" do
      assert UploadHandler.upload_entries(%Socket{assigns: %{__changed__: %{}}}, :avatar) == []
    end
  end
end
