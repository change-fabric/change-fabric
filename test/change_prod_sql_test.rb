# frozen_string_literal: true

require "minitest/autorun"
require_relative "../scripts/change_prod_sql"

class ChangeProdSqlTest < Minitest::Test
  Sql = ChangeProdSql

  def test_each_destructive_form
    [ "DROP TABLE users", "drop index ix", "TRUNCATE users", "truncate table a, b",
      "ALTER TABLE users DROP COLUMN email", "DELETE FROM users", "UPDATE users SET a = 1",
      "WITH x AS (SELECT 1) DELETE FROM users" ].each { |sql| assert Sql.destructive?(sql), sql }
  end

  def test_where_makes_delete_and_update_bounded
    refute Sql.destructive?("DELETE FROM users WHERE id = 1")
    refute Sql.destructive?("update users set a = 1 where id = 1")
    refute Sql.destructive?("DELETE FROM users\nWHERE id IN (SELECT id FROM old)")
  end

  def test_a_where_inside_a_subquery_is_not_the_statements_own
    assert Sql.destructive?("DELETE FROM users USING (SELECT id FROM old WHERE x) o")
    assert Sql.destructive?("UPDATE users SET a = (SELECT 1 WHERE true)")
  end

  def test_a_data_modifying_cte_is_destructive
    [ "WITH x AS (DELETE FROM t WHERE id = 1 RETURNING *) SELECT * FROM x",
      "with x as (update t set a = 1 where id = 1 returning *) select * from x",
      "WITH x AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * FROM x",
      "WITH x AS (MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE RETURNING *) SELECT 1",
      "WITH a AS (SELECT 1), b AS (TRUNCATE t) SELECT * FROM a",
      "WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x",
      "WITH RECURSIVE r AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 3), d AS (DELETE FROM t RETURNING *) SELECT * FROM d" ].each do |sql|
      statement = Sql.analyze(sql).first
      assert statement.destructive, sql
      assert_equal "with_dml", statement.kind, sql
    end
  end

  def test_a_read_only_cte_is_not_destructive
    refute Sql.destructive?("WITH x AS (SELECT * FROM t WHERE id = 1) SELECT * FROM x")
    refute Sql.destructive?("WITH x AS (SELECT * FROM t FOR UPDATE) SELECT * FROM x")
    refute Sql.destructive?("WITH x AS (SELECT 'delete from t') SELECT * FROM x")
    refute Sql.destructive?("WITH x AS (SELECT 1 /* drop */) SELECT * FROM x")
    refute Sql.destructive?("SELECT 1; WITH x AS (SELECT 2) SELECT * FROM x")
  end

  def test_plain_reads_and_inserts_are_not_destructive
    refute Sql.destructive?("SELECT * FROM users")
    refute Sql.destructive?("INSERT INTO users (a) VALUES (1)")
    refute Sql.destructive?("INSERT INTO t VALUES (1) ON CONFLICT (id) DO UPDATE SET a = 2")
    refute Sql.destructive?("SELECT * FROM users FOR UPDATE")
    refute Sql.destructive?("CREATE TABLE t (id int REFERENCES u ON DELETE CASCADE ON UPDATE CASCADE)")
    refute Sql.destructive?("")
    refute Sql.destructive?("  ;  ")
  end

  def test_keywords_in_strings_comments_and_quoted_identifiers_do_not_count
    refute Sql.destructive?("SELECT 'drop table users; delete from t'")
    refute Sql.destructive?("SELECT 1 -- drop table users")
    refute Sql.destructive?("SELECT 1 /* truncate users */")
    refute Sql.destructive?(%(SELECT "drop" FROM t))
    refute Sql.destructive?("SELECT $$drop table x$$")
    refute Sql.destructive?("SELECT 'it''s a drop'")
  end

  def test_comments_and_strings_do_not_hide_a_real_statement
    assert Sql.destructive?("/* harmless */ DROP TABLE users")
    assert Sql.destructive?("SELECT 'a;b'; DROP TABLE users")
    assert Sql.destructive?("DROP -- c\n TABLE users")
    assert Sql.destructive?("/* a /* nested */ still comment */ TRUNCATE t")
  end

  def test_multi_statement_flags_the_destructive_one
    statements = Sql.analyze("SELECT 1; DELETE FROM t WHERE id = 1; DROP TABLE t;")
    assert_equal %w[select delete drop], statements.map(&:kind)
    assert_equal [ false, false, true ], statements.map(&:destructive)
    assert(statements.all? { |s| s.sql_sha256.match?(/\A\h{64}\z/) })
  end

  def test_a_parse_failure_is_destructive
    [ "SELECT 'unterminated", "SELECT 1 /* open", "SELECT $$ open", "SELECT (1", "SELECT 1)" ].each do |sql|
      statements = Sql.analyze(sql)
      assert_equal [ "unparseable" ], statements.map(&:kind), sql
      assert Sql.destructive?(sql), sql
    end
  end

  def test_the_row_estimate_threshold
    refute Sql.destructive?("UPDATE t SET a = 1 WHERE id = 1", estimated_rows: 1000)
    assert Sql.destructive?("UPDATE t SET a = 1 WHERE id = 1", estimated_rows: 1001)
    refute Sql.destructive?("UPDATE t SET a = 1 WHERE id = 1", estimated_rows: 50, threshold: 50)
    assert Sql.destructive?("UPDATE t SET a = 1 WHERE id = 1", estimated_rows: 51, threshold: 50)
    assert Sql.destructive?("SELECT 1", estimated_rows: "many")
    assert Sql.destructive?("SELECT 1", estimated_rows: -1)
    refute Sql.destructive?("SELECT 1", estimated_rows: nil)
  end

  def test_the_op_threshold_defaults_and_is_overridable
    config = { "change_config" => { "operations" => { "a" => { "row_threshold" => 25 }, "b" => { "row_threshold" => 0 } } } }
    assert_equal 25, Sql.threshold_for(config, "a")
    assert_equal 1000, Sql.threshold_for(config, "b")
    assert_equal 1000, Sql.threshold_for(config, "missing")
    assert_equal 1000, Sql.threshold_for(nil, "a")
  end
end
