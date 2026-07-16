local cachedPlayers = {}
local frameworkJobs = Framework.GetFrameworkJobs()

local function cachePlayerJobs(source)
    local identifier = Framework.GetPlayerIdentifier(source)
    local result = MySQL.query.await(
        "SELECT job, minutes, amount, data FROM `filo_paychecks` WHERE citizenid = ?",
        { identifier }
    )

    cachedPlayers[identifier] = { jobs = {}, paychecks = {} }

    if result and #result > 0 then
        for _, row in ipairs(result) do
            local ok, decoded = pcall(json.decode, row.data)
            if ok and decoded and next(decoded) then
                cachedPlayers[identifier].jobs[row.job] = decoded
            end
            cachedPlayers[identifier].paychecks[row.job] = row.amount
        end
    else
        local playerJob = Framework.GetPlayerJobData(source)
        local frameworkJob = frameworkJobs[playerJob.jobName]
        if not frameworkJob then return end

        local defaultPaycheck = frameworkJob.grades[playerJob.gradeRank].payment or 0
        local jobData = {
            jobLabel   = frameworkJob.label,
            grade      = playerJob.gradeRank,
            gradeLabel = playerJob.gradeLabel,
            paycheck   = defaultPaycheck,
            offDutyPay = frameworkJob.offDutyPay or false,
        }

        MySQL.query(
            "INSERT INTO `filo_paychecks` (citizenid, job, minutes, amount, data) VALUES (?, ?, 0, 0, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)",
            { identifier, playerJob.jobName, json.encode(jobData) }
        )

        cachedPlayers[identifier].jobs[playerJob.jobName] = jobData
        cachedPlayers[identifier].paychecks[playerJob.jobName] = 0
    end
end

function AddPaycheck(identifier, job, amount)
    if not cachedPlayers[identifier] then return end

    cachedPlayers[identifier].paychecks[job] = (cachedPlayers[identifier].paychecks[job] or 0) + amount

    MySQL.query(
        "INSERT INTO `filo_paychecks` (citizenid, job, minutes, amount, data) VALUES (?, ?, 0, ?, '{}') ON DUPLICATE KEY UPDATE amount = amount + VALUES(amount)",
        { identifier, job, amount }
    )

    DebugPrint(("Adding paycheck for %s for %d to %s"):format(job, amount, identifier))

    if Config.NotifyOnPaycheck then
        local source = Framework.GetPlayerSource(identifier)
        if not source then return end

        local jobLabel = cachedPlayers[identifier].jobs[job] and cachedPlayers[identifier].jobs[job].jobLabel or job
        if Config.NotifyType == "framework" then
            Notify.SendNotification(source, "Paycheck Received",
                "You have received a paycheck of $" .. amount .. " for your work at " .. jobLabel, "info")
        elseif Config.NotifyType == "lb-phone" then
            Phone.SendEmail(source,
                job .. "paychecks@filo.com",
                "Payroll Notification: " .. jobLabel,
                "You have received a paycheck of $" .. amount .. " for your work at " .. jobLabel
            )
        end
    end
end

CreateThread(function()
    for _, source in pairs(Framework.GetPlayers()) do
        local identifier = Framework.GetPlayerIdentifier(source)
        if not cachedPlayers[identifier] then cachePlayerJobs(source) end
    end

    while true do
        for _, source in pairs(Framework.GetPlayers()) do
            local identifier = Framework.GetPlayerIdentifier(source)
            if not cachedPlayers[identifier] then cachePlayerJobs(source) end

            local playerJob = Framework.GetPlayerJobData(source)
            if playerJob and playerJob.jobName == 'unemployed' then goto skip end

            local accountBalance = Banking.GetAccountMoney(playerJob.jobName) or 0
            local playerMinutes  = GetPlayerMinutes(identifier, playerJob.jobName) or 0
            playerMinutes        += 1

            if playerMinutes % Config.PaycheckInterval ~= 0 then
                SetPlayerMinutes(identifier, playerJob.jobName, playerMinutes)
                goto skip
            else
                SetPlayerMinutes(identifier, playerJob.jobName, 0)
            end

            local jobData = cachedPlayers[identifier].jobs[playerJob.jobName]

            if not jobData then
                local frameworkJob = frameworkJobs[playerJob.jobName]
                if not frameworkJob then goto skip end

                local defaultPaycheck = frameworkJob.grades[playerJob.gradeRank].payment or 0
                jobData = {
                    jobLabel   = frameworkJob.label,
                    grade      = playerJob.gradeRank,
                    gradeLabel = playerJob.gradeLabel,
                    paycheck   = defaultPaycheck,
                    offDutyPay = frameworkJob.offDutyPay or false,
                }
                cachedPlayers[identifier].jobs[playerJob.jobName] = jobData

                MySQL.query(
                    "INSERT INTO `filo_paychecks` (citizenid, job, minutes, amount, data) VALUES (?, ?, 0, 0, ?) ON DUPLICATE KEY UPDATE data = VALUES(data)",
                    { identifier, playerJob.jobName, json.encode(jobData) }
                )
            end

            if jobData.deductSocietyMoney and accountBalance < jobData.paycheck then
                DebugPrint("Society account " .. playerJob.jobName .. " has insufficient funds for " .. identifier)
                SetPlayerMinutes(identifier, playerJob.jobName, playerMinutes)
                goto skip
            end

            if jobData.paycheck < 1 then
                DebugPrint("Paycheck amount is less than 1 for " .. playerJob.jobName .. " for " .. identifier)
                goto skip
            end

            if not jobData.offDutyPay and not playerJob.onDuty then
                DebugPrint("Off duty pay is disabled and player is not on duty for " ..
                    playerJob.jobName .. " for " .. identifier)
                goto skip
            end

            if jobData.deductSocietyMoney then
                Banking.RemoveAccountMoney(playerJob.jobName, jobData.paycheck)
            end

            AddPaycheck(identifier, playerJob.jobName, jobData.paycheck)
            ::skip::
        end
        Wait(60000)
    end
end)

lib.callback.register("filo_paychecks:server:getAllPaychecks", function(source, identifier)
    local identifier = identifier or Framework.GetPlayerIdentifier(source)
    if not cachedPlayers[identifier] then return nil end

    return cachedPlayers[identifier].jobs, cachedPlayers[identifier].paychecks
end)

lib.callback.register("filo_paychecks:server:getPaycheckData", function(source, job, identifier)
    local identifier = identifier or Framework.GetPlayerIdentifier(source)
    if not cachedPlayers[identifier] then return nil end

    return cachedPlayers[identifier].jobs[job]
end)

lib.callback.register("filo_paychecks:server:updatePaycheckData", function(source, job, identifier, paycheck, offDutyPay)
    local identifier = identifier or Framework.GetPlayerIdentifier(source)
    if not cachedPlayers[identifier] then return false end
    if not cachedPlayers[identifier].jobs[job] then return false end

    cachedPlayers[identifier].jobs[job].paycheck   = paycheck
    cachedPlayers[identifier].jobs[job].offDutyPay = offDutyPay

    MySQL.query(
        "UPDATE `filo_paychecks` SET data = ? WHERE citizenid = ? AND job = ?",
        { json.encode(cachedPlayers[identifier].jobs[job]), identifier, job }
    )

    return true
end)

lib.callback.register("filo_paychecks:server:claimPaycheck", function(source, job)
    local identifier = Framework.GetPlayerIdentifier(source)
    if not cachedPlayers[identifier] then return false end

    local paycheck = cachedPlayers[identifier].paychecks[job]
    if not paycheck or paycheck < 1 then return false end

    if not Framework.AddAccountBalance(source, "cash", paycheck) then
        DebugPrint("Failed to add paycheck to player " .. identifier)
        return false
    end

    cachedPlayers[identifier].paychecks[job] = 0

    MySQL.query(
        "UPDATE `filo_paychecks` SET amount = 0 WHERE citizenid = ? AND job = ?",
        { identifier, job }
    )

    DebugPrint("Claimed paycheck for " .. identifier .. " for " .. job)
    Notify.SendNotification(source, 'Paycheck Claimed', 'You have claimed your paycheck of $' .. paycheck .. '.',
        'success')

    return true
end)

AddEventHandler('community_bridge:Server:OnPlayerLoaded', function(source)
    local identifier = Framework.GetPlayerIdentifier(source)
    if not identifier then return end
    if not cachedPlayers[identifier] then cachePlayerJobs(source) end
end)

AddEventHandler('community_bridge:Server:OnPlayerUnload', function(source)
    local identifier = Framework.GetPlayerIdentifier(source)
    if not identifier then return end
    cachedPlayers[identifier] = nil
end)
