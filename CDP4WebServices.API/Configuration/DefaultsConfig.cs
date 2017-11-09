﻿// --------------------------------------------------------------------------------------------------------------------
// <copyright file="DefaultsConfig.cs" company="RHEA System S.A.">
//   Copyright (c) 2016 RHEA System S.A.
// </copyright>
// --------------------------------------------------------------------------------------------------------------------

namespace CDP4WebServices.API.Configuration
{
    /// <summary>
    /// The default properties configuration
    /// </summary>
    public class DefaultsConfig
    {
        /// <summary>
        /// Initializes a new instance of the <see cref="DefaultsConfig"/> class.
        /// </summary>
        public DefaultsConfig()
        {
            this.PersonPassword = "pass";
            this.DevServerPath = "http://localhost:4200/app";
            this.LocationServicePath = "http://freegeoip.net/json/";
            this.ContributorsCacheTimeout = 60;
        }

        /// <summary>
        /// Gets or sets the default person password.
        /// </summary>
        /// <remarks>
        /// The default password to assign to new users
        /// </remarks>
        public string PersonPassword { get; set; }

        /// <summary>
        /// Gets or sets the default path to the development server where the web app is served.
        /// </summary>
        /// <remarks>
        /// The default path to assign to the development server
        /// </remarks>
        public string DevServerPath { get; set; }

        /// <summary>
        /// Gets or sets the location service path.
        /// </summary>
        public string LocationServicePath { get; set; }

        /// <summary>
        /// Gets or sets the contributors cache timeout.
        /// </summary>
        public int ContributorsCacheTimeout { get; set; }
    }
}