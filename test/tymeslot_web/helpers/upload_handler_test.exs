defmodule TymeslotWeb.Helpers.UploadHandlerTest do
  @moduletag :utils
  use TymeslotWeb.ConnCase, async: true
  alias TymeslotWeb.Helpers.UploadHandler

  describe "get_upload_opts/1" do
  @moduletag :utils
    test "returns correct options for :avatar" do
      opts = UploadHandler.get_upload_opts(:avatar)
      assert opts[:max_entries] == 1
      assert is_list(opts[:accept])
    end

    test "returns correct options for :background_image" do
      opts = UploadHandler.get_upload_opts(:background_image)
      assert opts[:max_entries] == 1
      assert ".jpg" in opts[:accept] or ".png" in opts[:accept]
    end

    test "returns correct options for :background_video" do
      opts = UploadHandler.get_upload_opts(:background_video)
      assert opts[:max_entries] == 1
      assert ".mp4" in opts[:accept]
    end
  end

  describe "create_upload_result/3" do
    test "returns structured map" do
      result = UploadHandler.create_upload_result(:success, %{id: 1}, ["none"])
      assert result.status == :success
      assert result.data.id == 1
      assert result.errors == ["none"]
      assert %DateTime{} = result.timestamp
    end
  end
end
