local instanceId = barWidget.getConfig("instance_id")
local region = barWidget.getConfig("region")
local lastIp = ""

-- Track the live state locally to know what action to execute on click
local currentStatus = "UNKNOWN"

-- Helper to cleanly overwrite the isolated devbox configuration block
local function updateSshConfig(ip)
    if ip == lastIp then
        return
    end
    lastIp = ip
    -- Construct the clean configuration block as a string literal
    local configContent = string.format([[
Host aws-ubuntu
    HostName %s
    User ubuntu
    IdentityFile ~/.ssh/aws-ideapad-laptop.pem
]], ip)

    -- Define the absolute path for the isolated config target
    local homeDir = noctalia.getenv("HOME") or "/home/matthew"
    local configPath = homeDir .. "/.ssh/conf.d/aws-ubuntu"

    -- Use Noctalia's native off-thread file writer
    noctalia.writeFile(configPath, configContent)
    
    noctalia.notify("SSH Config", "Updated 'aws-ubuntu' file to IP: " .. ip)
    noctalia.log("SSH clean overwrite successful at: " .. configPath)
end

-- Helper to update the widget UI profile based on state strings
local function updateUI(state)
    currentStatus = state
    barWidget.setText(string.upper(state))

    if state == "running" then
        barWidget.setText("🏃 Running") -- Play icon
        barWidget.setTooltip("Dev Box is online. Click to STOP.")
        barWidget.setColor("#4ade80")       -- Vibrant Green (Text)
    elseif state == "stopped" then
        barWidget.setText("🛑 Stopped") -- Stop icon
        barWidget.setTooltip("Dev Box is offline. Click to START.")
        barWidget.setColor("#f87171")       -- Soft Red (Text)
    elseif state == "pending" or state == "stopping" then
        barWidget.setText("⏳ Transitioning") -- Transition icon
        barWidget.setColor("#fbbf24")       -- Amber/Yellow
        barWidget.setTooltip("State transitioning: " .. state .. "...")
    else
        barWidget.setTooltip("Unable to reach AWS or resolve instance state.")
        barWidget.setColor("#f87171")       -- Soft Red (Text)
    end
end

-- Asynchronously polls AWS for status and IP via structured JSON
local function fetchAwsStatus()
    local instanceId = barWidget.getConfig("instance_id")
    local region = barWidget.getConfig("region")

    if not instanceId or not region then
        updateUI("UNKNOWN")
        return
    end

    -- Construct a multi-property JSON query dictionary
    local cmd = string.format(
        'aws ec2 describe-instances --profile noctalia-widget --instance-ids "%s" --region "%s" --query "Reservations[0].Instances[0].[State.Name, PublicIpAddress || NetworkInterfaces[0].Association.PublicIp]" --output json | jq -c .',
        instanceId, region
    )

    noctalia.runAsync(cmd, function(result)
        if not result then
            updateUI("UNKNOWN")
            return
        end

        local rawOutput = result.stdout or result.body or result[1]
        if type(rawOutput) ~= "string" then
            rawOutput = ""
        end

        rawOutput = string.gsub(rawOutput, "^%s*(.-)%s*$", "%1")

        if rawOutput == "" then
            updateUI("UNKNOWN")
            return
        end
        -- local state, publicIp = string.match(rawOutput, '^%["([^"]+)"%s*,%s*"*([^"%]]*)"*%]$')
        local state, publicIp = string.match(rawOutput, '^%["([^"]+)"%s*,%s*"*([%w%.%-_/]*)"*%]$')

        updateUI(state)
        if publicIp ~= "" then
            updateSshConfig(publicIp)
        end
    end)
end

-- Noctalia Lifecycle Hook: Fires periodically
function update()
    -- Set polling rate: Check status every 15 seconds
    noctalia.setUpdateInterval(15000)
    fetchAwsStatus()
end

-- Noctalia UI Hook: Handle primary interaction toggles
function onClick()
    local action = ""
    
    if currentStatus == "stopped" then
        action = "start-instances"
        -- noctalia.notify("AWS Box", "Sending start instruction...")
        updateUI("pending")
    elseif currentStatus == "running" then
        action = "stop-instances"
        noctalia.notify("AWS Box", "Sending stop instruction...")
        updateUI("stopping")
    else
        noctalia.notify("AWS Box", "Instance busy or status unknown. Retrying query...")
        fetchAwsStatus()
        return
    end

    local cmd = string.format("aws ec2 --profile noctalia-widget %s --instance-ids '%s' --region '%s'", action, instanceId, region)
    -- noctalia.notify("Running CMD:", cmd)
    
    noctalia.runAsync(cmd, function(_)
        -- Give AWS a tiny window to register the instruction, then force a status poll
        fetchAwsStatus()
    end)
end

-- Allow a right-click to force a manual instant refresh
function onRightClick()
    fetchAwsStatus()
end

-- =========================================================================
-- INITIALIZATION BLOCK
-- =========================================================================
-- Force Noctalia to render placeholders instantly during layout creation
barWidget.setText("Initializing")

-- Immediately start pulling actual AWS infrastructure metrics
fetchAwsStatus()
