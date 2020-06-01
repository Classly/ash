defmodule Ash.Test.Dsl.Resource.Actions.ReadTest do
  use ExUnit.Case, async: true

  defmacrop defposts(do: body) do
    quote do
      defmodule Post do
        use Ash.Resource, name: "posts", type: "post"

        unquote(body)
      end
    end
  end

  describe "representation" do
    test "it creates an action" do
      defposts do
        actions do
          read :default
        end
      end

      assert [
               %Ash.Resource.Actions.Read{
                 name: :default,
                 primary?: true,
                 type: :read
               }
             ] = Ash.actions(Post)
    end
  end

  describe "validation" do
    test "it fails if `name` is not an atom" do
      assert_raise(
        Ash.Error.ResourceDslError,
        "actions -> read:\n  action name must be an atom",
        fn ->
          defposts do
            actions do
              read "default"
            end
          end
        end
      )
    end

    test "it fails if `primary?` is not a boolean" do
      assert_raise(
        Ash.Error.ResourceDslError,
        "actions -> read -> default:\n  expected :primary? to be an boolean, got: 10",
        fn ->
          defposts do
            actions do
              read :default, primary?: 10
            end
          end
        end
      )
    end
  end
end
