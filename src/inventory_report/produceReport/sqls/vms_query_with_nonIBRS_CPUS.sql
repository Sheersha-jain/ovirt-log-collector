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
    SELECT
        s.vm_name AS "Virtual Machine",
        d.cpu_name AS "CPU Name"
    FROM
        vm_dynamic d
    INNER JOIN vm_static s ON d.vm_guid = s.vm_guid
    WHERE cpu_name NOT ILIKE '%-IBRS'
) TO STDOUT WITH CSV DELIMITER E'\|' HEADER;
