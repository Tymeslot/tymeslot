defmodule Tymeslot.Auth.UsersWhereTest do
  use Tymeslot.DataCase, async: true

  @moduletag :auth

  alias Tymeslot.Auth

  setup do
    kept = insert(:user, name: "Kept for filter #{System.unique_integer([:positive])}")
    _other = insert(:user)
    %{kept: kept, compose: fn query -> where(query, [u], u.name == ^kept.name) end}
  end

  test "list_user_ids_where/1 returns the ids the filter keeps", %{kept: kept, compose: compose} do
    assert Auth.list_user_ids_where(compose) == [kept.id]
  end

  test "count_users_where/1 counts the accounts the filter keeps", %{compose: compose} do
    assert Auth.count_users_where(compose) == 1
    assert Auth.count_users_where(&where(&1, [u], false)) == 0
  end
end
