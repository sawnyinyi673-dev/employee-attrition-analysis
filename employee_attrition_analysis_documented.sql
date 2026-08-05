/* =============================================================================
   EMPLOYEE ATTRITION ANALYSIS
   Departure, salary, and tenure across departments and hire-year cohorts
   =============================================================================

   BUSINESS QUESTION
   -----------------
   Do lower-paid employees leave the company more often than higher-paid ones?
   And if they do, is pay the real reason - or is it just that lower-paid people
   tend to be newer, and newer people leave everywhere?

   DATASET
   -------
   MySQL "employees" sample database (the standard public HR dataset, ~300k
   employee records). Tables used:
     - dept_emp     : which department each employee belongs to, and for how long
     - salaries     : salary history (one row per salary period per employee)
     - departments  : department id -> department name
     - employees    : one row per employee, includes hire_date

   THE ONE CONVENTION YOU MUST KNOW TO READ THIS DATA
   --------------------------------------------------
   This dataset has no "active / left" flag. Instead, records that are still
   ongoing carry an end date (to_date) of '9999-01-01'.
     - to_date = '9999-01-01'  ->  record is still current (person is active)
     - any other to_date        ->  record has ended
   So an employee is treated as DEPARTED if they have NO department record
   ending in '9999-01-01'. This single idea drives the whole analysis.

   HOW THE ANALYSIS IS BUILT (read this to follow the story)
   ---------------------------------------------------------
   The queries build on each other in a deliberate order:

     STEP 1  Build two base tables: the departed employees, then a combined
             table of every employee (current + departed) with one salary each.

     STEP 2  Departure rate by DEPARTMENT.
             Finding: it is flat - about 1 in 5 leaves in every department.
             So the department does not explain who leaves.

     STEP 3  Departure rate by SALARY BAND (quartiles within each department).
             Finding: leaving is concentrated in the lowest-paid quartile,
             in every department.

     STEP 4  Average TENURE of leavers by salary band.
             Finding: leavers are both low-paid AND shorter-tenured. This raises
             a fair doubt - maybe it is not pay, just newness.

     STEP 5  Consolidated table: attrition rate and leaver tenure side by side.

     STEP 6  COHORT test: compare salary bands WITHIN the same hire year, so
             everyone being compared started at the same time (same "newness").
             Finding: the lowest-paid band still leaves more in every hire year.
             So the effect is linked to pay, not only to tenure. The doubt from
             Step 4 is answered.

     STEP 7  Cohort test WITH department added, to locate where the effect is
             largest for targeting.

   HEADLINE FINDINGS
   -----------------
     - Departure rate is flat across departments (~19.5% to 20.5%).
     - Within every department, the lowest-paid quartile leaves far more than
       the highest-paid quartile.
     - Holding hire year constant, the lowest-paid band still leaves more in all
       hire-year cohorts - so this is a pay-level effect, not just a tenure one.
     - By volume, the lowest-paid band of the two largest departments
       (Development and Production) accounts for roughly a quarter of all company
       departures. By rate, Sales, Finance, and Marketing show the sharpest
       low-paid-band departure rates.

   KNOWN LIMITATIONS (important - the analysis is honest about these)
   -----------------------------------------------------------------
     1. SALARY IS MEASURED AT DIFFERENT MOMENTS.
        For departed employees, salary is their FINAL salary (frozen at exit).
        For current employees, salary is their CURRENT salary (as of the latest
        date in the data). Salaries rise over time, so a leaver's salary stopped
        climbing earlier and tends to fall into a lower band for that reason
        alone. This means the SIZE of the pay effect is likely overstated. The
        DIRECTION of the finding (low pay linked to leaving) is still safe.

     2. ASSOCIATION, NOT PROVEN CAUSE.
        The analysis shows a strong, consistent link between low pay and higher
        attrition. It does not prove that raising pay would reduce attrition.
        Confirming cause would need a controlled pay change measured over time.

   NOTE ON PORTABILITY
   -------------------
   Written for MySQL. In MySQL, "/" returns a decimal, so "x * 100 / y" gives a
   correct rate. In some databases (PostgreSQL, SQL Server) integer division
   truncates, so "x * 100.0 / y" is the safer habit. Some queries below already
   use 100.0; a couple use 100. In MySQL both behave the same.

   AUTHOR : Saw
   ============================================================================= */


/* =============================================================================
   STEP 1a - BUILD THE LIST OF DEPARTED EMPLOYEES
   -----------------------------------------------------------------------------
   Goal: one row per employee who has LEFT, carrying their final salary,
   department, and the end date of that final salary (used later as their
   approximate departure date for tenure).
   ============================================================================= */
DROP TEMPORARY TABLE IF EXISTS departed_employees;
CREATE TEMPORARY TABLE departed_employees AS
WITH table_1 AS (
    SELECT
        de.emp_no,
        s.salary,
        s.to_date,
        d.dept_name,
        /* Each employee can have several salary rows over time. Number them so
           the most recent salary gets rn = 1 (latest salary end-date first).
           This lets us keep only the FINAL salary for each departed employee. */
        ROW_NUMBER() OVER (
            PARTITION BY de.emp_no
            ORDER BY s.to_date DESC, de.to_date DESC
        ) AS rn
    FROM dept_emp de
    JOIN salaries s
        ON de.emp_no = s.emp_no
    JOIN departments d
        ON de.dept_no = d.dept_no
    /* Keep only DEPARTED employees: anyone who does NOT appear with a current
       ('9999-01-01') department record. No ongoing record = they have left.
       Note: this must test the PERSON, not the row. A simple
       "de.to_date != '9999-01-01'" would wrongly flag internal transfers as
       departures, because a transferred employee still has an old closed
       department row alongside their current one. */
    WHERE de.emp_no NOT IN (
        SELECT emp_no
        FROM dept_emp
        WHERE to_date = '9999-01-01'
    )
)
SELECT
    emp_no,
    dept_name,
    salary,
    to_date,                 -- end date of the final salary ~ departure date
    1 AS departed_employees  -- flag: 1 = this person has left
FROM table_1
WHERE rn = 1;                -- keep only the final salary row per person

-- Inspection check (safe to run, not part of the analysis)
SELECT * FROM departed_employees;


/* =============================================================================
   STEP 1b - COMBINE CURRENT + DEPARTED INTO ONE EMPLOYEE TABLE
   -----------------------------------------------------------------------------
   Goal: a single table holding EVERY employee, each with one salary, one
   department, an end date, and a flag for whether they left. This table is the
   foundation for every query below.
   ============================================================================= */
CREATE TEMPORARY TABLE emp_salary AS
    /* Current employees: BOTH their department record and their salary record
       are still ongoing ('9999-01-01'). Flag 0 = still employed.
       Note: for these rows, to_date is the '9999-01-01' marker, NOT a real date.
       That is fine because tenure (Step 4) only uses departed employees. */
    SELECT
        de.emp_no,
        d.dept_name,
        s.salary,
        de.to_date,
        0 AS departed_employees
    FROM dept_emp de
    JOIN salaries s
        ON de.emp_no = s.emp_no
       AND de.to_date = '9999-01-01'
       AND s.to_date = '9999-01-01'
    JOIN departments d
        ON de.dept_no = d.dept_no

    UNION ALL

    /* Departed employees from Step 1a (already flagged 1, already deduped). */
    SELECT *
    FROM departed_employees;

-- Inspection check
select * from emp_salary;


/* =============================================================================
   STEP 2 - DEPARTURE RATE BY DEPARTMENT
   -----------------------------------------------------------------------------
   Goal: for each department, what share of employees have left?
   Finding: the rate is flat (~20%) across all departments. This tells us the
   department is NOT the driver of who leaves - the signal must live elsewhere.
   ============================================================================= */
WITH aggregated AS (
    SELECT
        dept_name,
        /* Count leavers in this department ... */
        SUM(CASE WHEN departed_employees = 1 THEN 1 ELSE 0 END) AS departed_employees,
        /* ... and current staff ... */
        SUM(CASE WHEN departed_employees = 0 THEN 1 ELSE 0 END) AS current_employees,
        /* ... and the department total. */
        COUNT(*) AS total_employees
    FROM emp_salary
    GROUP BY dept_name
)
SELECT
    dept_name,
    departed_employees,
    current_employees,
    total_employees,
    /* NULLIF guards against divide-by-zero if a department had no employees. */
    ROUND(departed_employees * 100.0 / NULLIF(total_employees, 0), 2) AS departure_rate
FROM aggregated;


/* =============================================================================
   STEP 3 - DEPARTURE RATE BY SALARY BAND (WITHIN EACH DEPARTMENT)
   -----------------------------------------------------------------------------
   Goal: inside each department, split employees into 4 salary quartiles and
   measure the departure rate of each band.
   Finding: the lowest-paid quartile leaves the most, in every department. This
   is where the signal lives - pay level, not department.
   ============================================================================= */
WITH salary_bucket AS (
    /* NTILE(4) splits each department's employees into 4 equal-sized bands by
       salary (lowest first). Band 1 = lowest-paid 25%, Band 4 = highest-paid.
       Done per department so pay is judged WITHIN a department, not across all. */
    SELECT *, NTILE(4) OVER (PARTITION BY dept_name ORDER BY salary ASC) AS salary_bucket
    FROM emp_salary
),
aggregated AS (
    SELECT
        dept_name,
        salary_bucket,
        SUM(CASE WHEN departed_employees = 1 THEN 1 ELSE 0 END) AS departed_employees_count,
        SUM(CASE WHEN departed_employees = 0 THEN 1 ELSE 0 END) AS current_employees_count,
        COUNT(*) AS total_employees
    FROM salary_bucket
    GROUP BY dept_name, salary_bucket
)
SELECT
    dept_name,
    /* Turn the numeric band into a readable pay label. */
    CASE salary_bucket
        WHEN 1 THEN 'Q1 - bottom 25% (lowest paid)'
        WHEN 2 THEN 'Q2 - lower middle 25%'
        WHEN 3 THEN 'Q3 - upper middle 25%'
        ELSE        'Q4 - top 25% (highest paid)'
    END AS salary_category,
    departed_employees_count,
    total_employees,   -- size of this department+band cell (not the whole dept)
    ROUND(departed_employees_count * 100.0 / total_employees, 2) AS departed_rate
FROM aggregated
ORDER BY departed_rate DESC;


/* =============================================================================
   STEP 3 (persisted) - SAME RESULT SAVED AS A TABLE FOR REUSE
   -----------------------------------------------------------------------------
   Identical logic to Step 3, stored as a temporary table so it can be joined to
   the tenure table in Step 5. Keeps salary_bucket numeric (no labels) so the
   join key stays simple.
   ============================================================================= */
CREATE TEMPORARY TABLE departed_employees_count AS
WITH salary_bucket AS (
    SELECT *, NTILE(4) OVER (PARTITION BY dept_name ORDER BY salary ASC) AS salary_bucket
    FROM emp_salary
),
aggregated AS (
    SELECT
        dept_name,
        salary_bucket,
        SUM(CASE WHEN departed_employees = 1 THEN 1 ELSE 0 END) AS departed_employees_count,
        SUM(CASE WHEN departed_employees = 0 THEN 1 ELSE 0 END) AS current_employees_count,
        COUNT(*) AS total_employees
    FROM salary_bucket
    GROUP BY dept_name, salary_bucket
)
SELECT
    dept_name,
    salary_bucket,
    departed_employees_count,
    total_employees,
    ROUND(departed_employees_count * 100.0 / total_employees, 2) AS departed_rate
FROM aggregated
ORDER BY departed_rate DESC;


/* =============================================================================
   STEP 4 - AVERAGE TENURE OF LEAVERS, BY SALARY BAND
   -----------------------------------------------------------------------------
   Goal: for each department+band, how many years did the leavers stay before
   leaving? This checks whether low-paid leavers are also the shorter-tenured
   ones - which would raise the doubt that the story is really about tenure,
   not pay.
   Finding: leavers are both low-paid and shorter-tenured. That doubt is real,
   and Step 6 (cohort) is what resolves it.

   TWO KEY TECHNIQUES IN THIS QUERY:
   (a) The buckets are cut over ALL employees (NTILE is not filtered), so they
       match the buckets in Step 3. This is why the Step 5 join is valid.
   (b) Tenure is averaged over DEPARTED employees only, using a CASE with no
       ELSE. When departed = 0, the CASE returns NULL, and AVG() skips NULLs.
       So current employees still sit inside the bucket, but do not enter the
       tenure average. (Their to_date is the '9999-01-01' marker, which would
       give a nonsense tenure - the NULL filter keeps it out.)
   ============================================================================= */
CREATE TEMPORARY TABLE departed_employees_avg_tenure AS
WITH emp_tenure AS (
    SELECT
        es.emp_no,
        es.dept_name,
        es.salary,
        e.hire_date,
        es.to_date,
        departed_employees,
        /* Tenure = years from hire to the record's end date. For departed
           employees this is hire -> departure (real tenure). For current
           employees it uses the '9999-01-01' marker and is meaningless - but
           the CASE filter below removes them from the average. */
        TIMESTAMPDIFF(year, e.hire_date, es.to_date) AS tenure
    FROM emp_salary es
    JOIN employees e
        ON es.emp_no = e.emp_no
),
salary_bucketed AS (
    SELECT
        *,
        NTILE(4) OVER (PARTITION BY dept_name ORDER BY salary ASC) AS salary_bucket
    FROM emp_tenure
)
SELECT
    dept_name,
    salary_bucket,
    /* Average tenure of LEAVERS only (no ELSE -> current staff become NULL ->
       skipped by AVG). */
    ROUND(AVG(CASE WHEN departed_employees = 1 THEN tenure END), 2) AS average_tenure
FROM salary_bucketed
GROUP BY dept_name, salary_bucket
ORDER BY salary_bucket, dept_name;

-- Inspection check
SELECT * FROM departed_employees_avg_tenure;


/* =============================================================================
   STEP 5 - CONSOLIDATED VIEW: ATTRITION RATE + LEAVER TENURE SIDE BY SIDE
   -----------------------------------------------------------------------------
   Goal: join the Step 3 attrition table to the Step 4 tenure table so both
   numbers appear together per department+band.
   Why the join is valid: both tables cut their quartiles with the SAME NTILE
   over ALL employees per department, so "bucket 1" means the same salary range
   and the same people in both. The join keys (dept_name + salary_bucket)
   therefore line up correctly.
   ============================================================================= */
WITH consolidated AS (
    SELECT
        dec_.dept_name,
        dec_.salary_bucket,
        deat.average_tenure,
        dec_.departed_employees_count,
        dec_.total_employees,
        dec_.departed_rate
    FROM departed_employees_count dec_
    JOIN departed_employees_avg_tenure deat
        ON dec_.dept_name = deat.dept_name
       AND dec_.salary_bucket = deat.salary_bucket
)
SELECT
    dept_name,
    CASE salary_bucket
        WHEN 1 THEN 'Q1 - bottom 25% (lowest paid)'
        WHEN 2 THEN 'Q2 - lower middle 25%'
        WHEN 3 THEN 'Q3 - upper middle 25%'
        ELSE        'Q4 - top 25% (highest paid)'
    END AS salary_category,
    average_tenure,             -- leavers only (see Step 4)
    departed_employees_count,
    total_employees,
    departed_rate
FROM consolidated;


/* =============================================================================
   STEP 6 - COHORT TEST: DOES PAY MATTER WHEN HIRE YEAR IS HELD CONSTANT?
   -----------------------------------------------------------------------------
   This is the core test of the whole project.

   The problem it solves: low-paid employees are often the newer ones, and newer
   people leave everywhere. So the Step 3 finding could be a tenure effect in
   disguise. To separate pay from tenure, compare salary bands WITHIN the same
   hire year - everyone in a hire-year group started at the same time, so they
   share the same "newness". If the lowest-paid band STILL leaves more inside a
   single hire year, then newness is not the explanation - pay is.

   Note on the buckets here: NTILE is partitioned by HIRE_YEAR (not by
   department). So "low-paid" means low-paid relative to everyone hired that
   same year. This is deliberate - it holds starting-year constant while judging
   pay. Department is not used in this version (Step 2 already showed department
   is flat, so it adds nothing to the "why").

   Finding: the lowest-paid band leaves more in every hire-year cohort. Pay is
   linked to leaving even at equal tenure.
   ============================================================================= */
WITH total_emp_info AS (
    SELECT
        es.emp_no,
        es.dept_name,
        es.salary,
        e.hire_date,
        es.to_date,
        departed_employees,
        YEAR(e.hire_date) AS hire_year   -- the cohort key: year the person started
    FROM emp_salary es
    JOIN employees e
        ON es.emp_no = e.emp_no
),
salary_bucketed AS (
    /* Pay quartiles cut WITHIN each hire year. */
    SELECT
        *,
        NTILE(4) OVER (PARTITION BY hire_year ORDER BY salary ASC) AS salary_bucket
    FROM total_emp_info
),
aggregated AS (
    SELECT
        hire_year,
        salary_bucket,
        SUM(CASE WHEN departed_employees = 1 THEN 1 ELSE 0 END) AS departed_employees_count,
        SUM(CASE WHEN departed_employees = 0 THEN 1 ELSE 0 END) AS current_employees_count,
        COUNT(*) AS total_employees
    FROM salary_bucketed
    GROUP BY hire_year, salary_bucket
)
SELECT
    hire_year,
    CASE salary_bucket
        WHEN 1 THEN 'Q1 - bottom 25% (lowest paid)'
        WHEN 2 THEN 'Q2 - lower middle 25%'
        WHEN 3 THEN 'Q3 - upper middle 25%'
        ELSE        'Q4 - top 25% (highest paid)'
    END AS salary_category,
    departed_employees_count,
    current_employees_count,
    total_employees,
    ROUND(departed_employees_count * 100 / total_employees, 2) AS pct_of_departed_employees
FROM aggregated
ORDER BY pct_of_departed_employees DESC;


/* =============================================================================
   STEP 7 - COHORT TEST WITH DEPARTMENT ADDED (FOR TARGETING)
   -----------------------------------------------------------------------------
   Same cohort logic as Step 6, but department is added to the grouping. Purpose
   is different: not to explain WHY people leave (Step 6 did that), but to show
   WHERE the effect is largest, so action can be targeted.

   Buckets are still cut per hire year (company-wide within the year), then split
   by department in the grouping.

   The filter "departed_employees_count > 30" removes very small cells. A rate
   built on a handful of people is noise (2 of 3 leavers reads as 66% and means
   nothing), so cells with 30 or fewer leavers are dropped before reading the
   table. This is a minimum-sample floor.

   Reading tip: this is the most granular table (hire year x department x band),
   so it is large. Use it for drill-down, not for the top-line story.
   ============================================================================= */
WITH total_emp_info AS (
    SELECT
        es.emp_no,
        es.dept_name,
        es.salary,
        e.hire_date,
        es.to_date,
        departed_employees,
        YEAR(e.hire_date) AS hire_year
    FROM emp_salary es
    JOIN employees e
        ON es.emp_no = e.emp_no
),
salary_bucketed AS (
    SELECT
        *,
        NTILE(4) OVER (PARTITION BY hire_year ORDER BY salary ASC) AS salary_bucket
    FROM total_emp_info
),
aggregated AS (
    SELECT
        hire_year,
        dept_name,
        salary_bucket,
        SUM(CASE WHEN departed_employees = 1 THEN 1 ELSE 0 END) AS departed_employees_count,
        SUM(CASE WHEN departed_employees = 0 THEN 1 ELSE 0 END) AS current_employees_count,
        COUNT(*) AS total_employees
    FROM salary_bucketed
    GROUP BY hire_year, dept_name, salary_bucket
)
SELECT
    hire_year,
    dept_name,
    CASE salary_bucket
        WHEN 1 THEN 'Q1 - bottom 25% (lowest paid)'
        WHEN 2 THEN 'Q2 - lower middle 25%'
        WHEN 3 THEN 'Q3 - upper middle 25%'
        ELSE        'Q4 - top 25% (highest paid)'
    END AS salary_category,
    departed_employees_count,
    current_employees_count,
    total_employees,
    ROUND(departed_employees_count * 100 / total_employees, 2) AS pct_of_departed_employees
FROM aggregated
WHERE departed_employees_count > 30   -- minimum-sample floor: drop tiny, noisy cells
ORDER BY pct_of_departed_employees DESC;
