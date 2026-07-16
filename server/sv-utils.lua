local playerHours = {}

local function EnsureTable()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS `filo_paychecks` (
            `citizenid`  VARCHAR(64)  NOT NULL,
            `job`        VARCHAR(64)  NOT NULL,
            `minutes`    INT          NOT NULL DEFAULT 0,
            `amount`     INT          NOT NULL DEFAULT 0,
            `data`       LONGTEXT     NOT NULL,
            PRIMARY KEY (`citizenid`, `job`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]], {}, function(result)
        if not result then
            print("^1[filo_paychecks] ERROR: Failed to create filo_paychecks table.^7")
        else
            DebugPrint("[filo_paychecks] Table ready.")
        end
    end)
end

CreateThread(function()
    while not MySQL do Wait(0) end
    EnsureTable()
    Wait(500)

    local result = MySQL.query.await("SELECT citizenid, job, minutes FROM `filo_paychecks`", {})
    if result then
        for _, row in ipairs(result) do
            playerHours[row.citizenid] = playerHours[row.citizenid] or {}
            playerHours[row.citizenid][row.job] = row.minutes
        end
        DebugPrint(("[filo_paychecks] Seeded %d hour records into cache."):format(#result))
    end
end)

function SetPlayerMinutes(identifier, job, minutes)
    playerHours[identifier] = playerHours[identifier] or {}
    playerHours[identifier][job] = minutes

    MySQL.query(
        "INSERT INTO `filo_paychecks` (citizenid, job, minutes, amount, data) VALUES (?, ?, ?, 0, '{}') ON DUPLICATE KEY UPDATE minutes = VALUES(minutes)",
        { identifier, job, minutes }
    )
end

function GetPlayerMinutes(identifier, job)
    local playerData = playerHours[identifier] or {}
    return playerData[job] or 0
end

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= cache.resource then return end

    for identifier, jobs in pairs(playerHours) do
        for job, minutes in pairs(jobs) do
            MySQL.query(
                "INSERT INTO `filo_paychecks` (citizenid, job, minutes, amount, data) VALUES (?, ?, ?, 0, '{}') ON DUPLICATE KEY UPDATE minutes = VALUES(minutes)",
                { identifier, job, minutes }
            )
        end
    end
end)
