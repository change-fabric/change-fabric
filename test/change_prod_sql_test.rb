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

  def test_only_the_allowlist_is_non_destructive
    [ "SELECT 1", "select * from t where a = 1", "SHOW search_path", "EXPLAIN SELECT * FROM t", "EXPLAIN DELETE FROM t",
      "INSERT INTO t (a) VALUES (1), (2)", "UPDATE t SET a = 1 WHERE id = 1", "DELETE FROM t WHERE id = 1",
      "BEGIN", "COMMIT", "ROLLBACK", "SET statement_timeout = 5000", "SET LOCAL lock_timeout = '2s'",
      "BEGIN; UPDATE t SET a = 1 WHERE id = 2; COMMIT" ].each { |sql| refute Sql.destructive?(sql), sql }
  end

  def test_everything_else_is_destructive
    [ "DO $$ BEGIN DELETE FROM t; END $$", "DO 'begin perform 1; end'", "CALL purge_all()", "COPY t FROM '/x'", "COPY t TO PROGRAM 'x'",
      "ALTER TABLE t ADD COLUMN a int", "ALTER ROLE app SUPERUSER", "GRANT ALL ON t TO u", "REVOKE ALL ON t FROM u",
      "CREATE TABLE t (id int)", "CREATE OR REPLACE FUNCTION f() RETURNS void AS $$ DELETE FROM t $$ LANGUAGE sql",
      "VACUUM FULL t", "REINDEX TABLE t", "MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE",
      "INSERT INTO t SELECT * FROM s", "INSERT INTO t VALUES (1) ON CONFLICT (id) DO UPDATE SET a = 2",
      "SELECT * INTO backup FROM t", "EXPLAIN ANALYZE DELETE FROM t", "EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET a = 1 WHERE b",
      "EXPLAIN (analyse) DELETE FROM t WHERE b", "SET ROLE admin", "SET SESSION AUTHORIZATION admin", "RESET ALL",
      "LOCK TABLE t", "REFRESH MATERIALIZED VIEW v", "NOTIFY c", "LISTEN c", "SAVEPOINT s", "frobnicate t", "(SELECT 1)" ].each do |sql|
      assert Sql.destructive?(sql), sql
    end
  end

  def test_one_unlisted_statement_makes_a_batch_destructive
    assert Sql.destructive?("SELECT 1; DO $$ BEGIN NULL; END $$; SELECT 2")
    assert Sql.analyze("SELECT 1; CALL f()").map(&:destructive) == [ false, true ]
  end

  # Forms the scanner does not tokenize with certainty make the whole batch destructive.
  def test_unusual_quoting_forms_make_the_whole_batch_destructive
    [ "SELECT E'it\\'s'; DELETE FROM t", # the reviewer's example: the escaped quote hides the DELETE
      "SELECT e'a'", "SELECT E'a\\nb'", "SELECT U&'d\\0061t\\+000061'", "SELECT u&'x'", %(SELECT U&"x" FROM t),
      "SELECT B'101'", "SELECT X'1F'", "SELECT b'1'", "SELECT $$a$$", "SELECT $tag$a$tag$", "SELECT $$",
      "SELECT $q1$x'; DELETE FROM t; --$q1$", "DO $q1$ BEGIN DELETE FROM t; END $q1$", "SELECT $a_1$a$a_1$", "SELECT $_$a$_$",
      "SELECT $1$", "SELECT $1$a$1$", "SELECT 1$", "SELECT a$b FROM t", "SELECT $", "SELECT $1a", "SELECT x$1",
      "SELECT 'a\\b'", "SELECT 'a' \\g", %(SELECT "a\\b" FROM t),
      "SELECT 1 /* a /* b */ c */", "SELECT 1 /* open", "SELECT 'open" ].each do |sql|
      assert Sql.destructive?(sql), sql
      assert_equal [ "unparseable" ], Sql.analyze(sql).map(&:kind), sql
    end
  end

  def test_control_and_non_ascii_characters_make_the_whole_batch_destructive
    [ "SELECT 1 -- c\rDELETE FROM t", "SELECT 1 --c\r\nDELETE FROM t", "SELECT 1;\fDELETE FROM t", "SELECT 1;\vDELETE FROM t",
      "SELECT 1;\0DELETE FROM t", "SELECT 1\u0001", "SELECT 1\u007f", "SELECT '\u00e9'", "SELECT 1 -- \u2028DELETE FROM t",
      "SELECT 1\u00a0FROM t", "SELECT \u0430 FROM t", "SELECT 1\xff".b ].each do |sql|
      assert Sql.destructive?(sql), sql.inspect
      assert_equal [ "unparseable" ], Sql.analyze(sql).map(&:kind), sql.inspect
    end
  end

  def test_tab_lf_and_a_line_comment_to_the_end_of_input_are_still_read
    refute Sql.destructive?("SELECT\t1\nFROM t -- trailing")
    refute Sql.destructive?("SELECT 1 -- note\nFROM t")
    assert Sql.destructive?("SELECT 1 -- note\n; DELETE FROM t")
    assert_equal %w[select delete], Sql.analyze("SELECT 1 -- a\n; DELETE FROM t WHERE a = 1").map(&:kind)
  end

  def test_plain_standard_quoting_is_still_read
    refute Sql.destructive?("SELECT 'it''s' , \"a\"\"b\" FROM t")
    refute Sql.destructive?("SELECT * FROM t WHERE a IN ('x', 'y') -- c")
    refute Sql.destructive?("SELECT 1 /* flat */")
    refute Sql.destructive?("SELECT $1, $2")
    refute Sql.destructive?("SELECT * FROM t WHERE a = $1 AND b=$23")
    refute Sql.destructive?("DELETE FROM t WHERE id = $1")
    refute Sql.destructive?("SELECT ($1)")
    refute Sql.destructive?("INSERT INTO t VALUES ('a'),('b')")
    assert Sql.destructive?("SELECT 'it''s'; DELETE FROM t")
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
    refute Sql.destructive?("INSERT INTO t VALUES (1) ON CONFLICT (id) DO NOTHING")
    refute Sql.destructive?("INSERT INTO t VALUES (1) RETURNING id")
    refute Sql.destructive?("SELECT * FROM users FOR UPDATE")
    refute Sql.destructive?("")
    refute Sql.destructive?("  ;  ")
  end

  def test_keywords_in_strings_comments_and_quoted_identifiers_do_not_count
    refute Sql.destructive?("SELECT 'drop table users; delete from t'")
    refute Sql.destructive?("SELECT 1 -- drop table users")
    refute Sql.destructive?("SELECT 1 /* truncate users */")
    refute Sql.destructive?(%(SELECT "drop" FROM t))
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
