--  Licensed under the Apache License, Version 2.0 (the "License");
--  you may not use this file except in compliance with the License.
--  You may obtain a copy of the License at
--
--      http://www.apache.org/licenses/LICENSE-2.0
--
--  Unless required by applicable law or agreed to in writing, software
--  distributed under the License is distributed on an "AS IS" BASIS,
--  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
--  See the License for the specific language governing permissions and
--  limitations under the License.
--
COPY (
    SELECT COALESCE((
        SELECT
            replace(replace(var_value::varchar,'1','Yes'),'0','No')
        FROM
            dwh_history_timekeeping
        WHERE
            var_name = 'DwhCurrentlyRunning'
        ), 'No'
    ) AS "DWH running",
    (
        SELECT
            var_value
        FROM
            dwh_history_timekeeping
        WHERE
            var_name = 'dwhHostname'
    ) AS "Host Name"
) TO STDOUT WITH CSV DELIMITER E'\|' HEADER;
