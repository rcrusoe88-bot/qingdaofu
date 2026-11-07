export namespace analyze {
	
	export class Drive {
	    Name: string;
	    Path: string;
	    Total: number;
	    Free: number;
	
	    static createFrom(source: any = {}) {
	        return new Drive(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.Name = source["Name"];
	        this.Path = source["Path"];
	        this.Total = source["Total"];
	        this.Free = source["Free"];
	    }
	}
	export class File {
	    Name: string;
	    Path: string;
	    Size: number;
	
	    static createFrom(source: any = {}) {
	        return new File(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.Name = source["Name"];
	        this.Path = source["Path"];
	        this.Size = source["Size"];
	    }
	}
	export class Node {
	    Name: string;
	    Path: string;
	    Size: number;
	    IsDir: boolean;
	    Files: number;
	    Children: Node[];
	    Largest?: File[];
	    Truncated?: boolean;
	
	    static createFrom(source: any = {}) {
	        return new Node(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.Name = source["Name"];
	        this.Path = source["Path"];
	        this.Size = source["Size"];
	        this.IsDir = source["IsDir"];
	        this.Files = source["Files"];
	        this.Children = this.convertValues(source["Children"], Node);
	        this.Largest = this.convertValues(source["Largest"], File);
	        this.Truncated = source["Truncated"];
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

export namespace metrics {
	
	export class DiskInfo {
	    Device: string;
	    Mountpoint: string;
	    Total: number;
	    Used: number;
	    Free: number;
	    UsedPercent: number;
	    Fstype: string;
	
	    static createFrom(source: any = {}) {
	        return new DiskInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.Device = source["Device"];
	        this.Mountpoint = source["Mountpoint"];
	        this.Total = source["Total"];
	        this.Used = source["Used"];
	        this.Free = source["Free"];
	        this.UsedPercent = source["UsedPercent"];
	        this.Fstype = source["Fstype"];
	    }
	}
	export class NetworkInfo {
	    Name: string;
	    BytesSent: number;
	    BytesRecv: number;
	    PacketsSent: number;
	    PacketsRecv: number;
	
	    static createFrom(source: any = {}) {
	        return new NetworkInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.Name = source["Name"];
	        this.BytesSent = source["BytesSent"];
	        this.BytesRecv = source["BytesRecv"];
	        this.PacketsSent = source["PacketsSent"];
	        this.PacketsRecv = source["PacketsRecv"];
	    }
	}
	export class ProcessInfo {
	    PID: number;
	    Name: string;
	    CPU: number;
	    Memory: number;
	    MemPct: number;
	
	    static createFrom(source: any = {}) {
	        return new ProcessInfo(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.PID = source["PID"];
	        this.Name = source["Name"];
	        this.CPU = source["CPU"];
	        this.Memory = source["Memory"];
	        this.MemPct = source["MemPct"];
	    }
	}
	export class Snapshot {
	    // Go type: time
	    CollectedAt: any;
	    HealthScore: number;
	    HealthMessage: string;
	    Hostname: string;
	    OS: string;
	    Platform: string;
	    UptimeSeconds: number;
	    CPUModel: string;
	    CPUCores: number;
	    CPUPercent: number;
	    MemTotal: number;
	    MemUsed: number;
	    MemPercent: number;
	    SwapTotal: number;
	    SwapUsed: number;
	    SwapPercent: number;
	    Disks: DiskInfo[];
	    Networks: NetworkInfo[];
	    NetRecvPerSec: number;
	    NetSentPerSec: number;
	    BatteryPercent: number;
	    BatteryCharging: boolean;
	    BatteryPresent: boolean;
	    TopProcesses: ProcessInfo[];
	
	    static createFrom(source: any = {}) {
	        return new Snapshot(source);
	    }
	
	    constructor(source: any = {}) {
	        if ('string' === typeof source) source = JSON.parse(source);
	        this.CollectedAt = this.convertValues(source["CollectedAt"], null);
	        this.HealthScore = source["HealthScore"];
	        this.HealthMessage = source["HealthMessage"];
	        this.Hostname = source["Hostname"];
	        this.OS = source["OS"];
	        this.Platform = source["Platform"];
	        this.UptimeSeconds = source["UptimeSeconds"];
	        this.CPUModel = source["CPUModel"];
	        this.CPUCores = source["CPUCores"];
	        this.CPUPercent = source["CPUPercent"];
	        this.MemTotal = source["MemTotal"];
	        this.MemUsed = source["MemUsed"];
	        this.MemPercent = source["MemPercent"];
	        this.SwapTotal = source["SwapTotal"];
	        this.SwapUsed = source["SwapUsed"];
	        this.SwapPercent = source["SwapPercent"];
	        this.Disks = this.convertValues(source["Disks"], DiskInfo);
	        this.Networks = this.convertValues(source["Networks"], NetworkInfo);
	        this.NetRecvPerSec = source["NetRecvPerSec"];
	        this.NetSentPerSec = source["NetSentPerSec"];
	        this.BatteryPercent = source["BatteryPercent"];
	        this.BatteryCharging = source["BatteryCharging"];
	        this.BatteryPresent = source["BatteryPresent"];
	        this.TopProcesses = this.convertValues(source["TopProcesses"], ProcessInfo);
	    }
	
		convertValues(a: any, classs: any, asMap: boolean = false): any {
		    if (!a) {
		        return a;
		    }
		    if (a.slice && a.map) {
		        return (a as any[]).map(elem => this.convertValues(elem, classs));
		    } else if ("object" === typeof a) {
		        if (asMap) {
		            for (const key of Object.keys(a)) {
		                a[key] = new classs(a[key]);
		            }
		            return a;
		        }
		        return new classs(a);
		    }
		    return a;
		}
	}

}

